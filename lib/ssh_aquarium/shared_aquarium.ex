defmodule SshAquarium.SharedAquarium do
  @moduledoc """
  Manages the shared fish aquarium state and animations.
  """

  use GenServer
  require Logger

  defstruct [
    :viewers,           # MapSet of viewer PIDs
    :fish,              # Map of fish_id -> fish_state
    :terminal_config,   # Terminal dimensions and cell size
    :animation_timer,   # Timer reference for animation loop
    :connection_counter,
    :fish_counter
  ]

  @fish_per_connection 100
  @animation_interval 16  # ~60 FPS

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def add_viewer(pid, viewer_pid) do
    GenServer.call(pid, {:add_viewer, viewer_pid})
  end

  def remove_viewer(pid, connection_id) do
    GenServer.cast(pid, {:remove_viewer, connection_id})
  end

  def handle_mouse_click(pid, connection_id, mouse_data) do
    GenServer.cast(pid, {:mouse_click, connection_id, mouse_data})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      viewers: MapSet.new(),
      fish: %{},
      terminal_config: nil,
      animation_timer: nil,
      connection_counter: 0,
      fish_counter: 0
    }
    
    {:ok, state}
  end

  @impl true
  def handle_call({:add_viewer, viewer_pid}, _from, state) do
    connection_id = state.connection_counter + 1
    new_viewers = MapSet.put(state.viewers, {connection_id, viewer_pid})
    
    Logger.info("Connection #{connection_id} joined. Total viewers: #{MapSet.size(new_viewers)}")
    
    # If this is the first viewer, detect terminal and start animation
    state = 
      if MapSet.size(state.viewers) == 0 do
        # Use more reasonable defaults - most terminals use 8x16 or similar
        terminal_config = %{
          term_columns: 80,
          term_rows: 24,
          cell_width: 8,
          cell_height: 16
        }
        
        # Add fish for this connection
        fish = add_fish_for_connection(state.fish, terminal_config, connection_id, @fish_per_connection, state.fish_counter)
        
        # Start animation
        {:ok, timer_ref} = :timer.send_interval(@animation_interval, self(), :animate)
        
        # Trigger immediate animation frame
        send(self(), :animate)
        
        %{state | 
          terminal_config: terminal_config,
          fish: fish,
          animation_timer: timer_ref,
          fish_counter: state.fish_counter + @fish_per_connection
        }
      else
        # Add fish for new connection
        if state.terminal_config do
          fish = add_fish_for_connection(state.fish, state.terminal_config, connection_id, @fish_per_connection, state.fish_counter)
          
          # Send setup to new viewer
          send_viewer_setup(viewer_pid)
          
          %{state | 
            fish: fish,
            fish_counter: state.fish_counter + @fish_per_connection
          }
        else
          state
        end
      end
    
    state = %{state | 
      viewers: new_viewers,
      connection_counter: connection_id
    }
    
    {:reply, connection_id, state}
  end

  @impl true
  def handle_cast({:remove_viewer, connection_id}, state) do
    # Find and remove the viewer
    new_viewers = MapSet.filter(state.viewers, fn {id, _pid} -> id != connection_id end)
    
    Logger.info("Connection #{connection_id} left. Remaining viewers: #{MapSet.size(new_viewers)}")
    
    # Remove fish owned by this connection with poof effect
    {fish_to_remove, remaining_fish} = 
      Enum.split_with(state.fish, fn {_fish_id, fish} -> fish.owner_id == connection_id end)
    
    # Create poof effects for removed fish
    Enum.each(fish_to_remove, fn {_fish_id, fish} ->
      create_poof_effect(fish, state.terminal_config)
    end)
    
    state = %{state | viewers: new_viewers, fish: Map.new(remaining_fish)}
    
    # Stop animation if no viewers left
    state = 
      if MapSet.size(new_viewers) == 0 and state.animation_timer do
        :timer.cancel(state.animation_timer)
        Logger.info("Stopping aquarium animation - no more viewers")
        %{state | 
          animation_timer: nil,
          fish: %{},
          terminal_config: nil,
          fish_counter: 0
        }
      else
        state
      end
    
    {:noreply, state}
  end

  @impl true
  def handle_cast({:mouse_click, connection_id, mouse_data}, state) do
    if state.terminal_config do
      handle_mouse_click_internal(connection_id, mouse_data, state.terminal_config, state.fish)
    end
    {:noreply, state}
  end

  @impl true
  def handle_info(:animate, state) do
    if MapSet.size(state.viewers) > 0 and state.terminal_config do
      {new_fish, output} = animate_fish(state.fish, state.terminal_config)
      
      if output != "" do
        Logger.debug("Broadcasting animation frame with #{byte_size(output)} bytes to #{MapSet.size(state.viewers)} viewers")
        broadcast_to_viewers(state.viewers, output)
      end
      
      {:noreply, %{state | fish: new_fish}}
    else
      {:noreply, state}
    end
  end

  # Helper Functions

  defp add_fish_for_connection(existing_fish, terminal_config, connection_id, count, fish_counter) do
    term_pixel_width = terminal_config.term_columns * terminal_config.cell_width
    term_pixel_height = terminal_config.term_rows * terminal_config.cell_height
    
    new_fish = 
      for i <- 1..count, into: %{} do
        fish_id = fish_counter + i
        fish = %{
          id: fish_id,
          owner_id: connection_id,
          px: :rand.uniform() * (term_pixel_width - 64),
          py: :rand.uniform() * (term_pixel_height - 36),
          dx: (:rand.uniform() - 0.5) * 0.08 * terminal_config.cell_width,
          dy: (:rand.uniform() - 0.5) * 0.02 * terminal_config.cell_height,
          bobbing_time: :rand.uniform() * 100,
          bubbles: [],
          placement_id: fish_id
        }
        {fish_id, fish}
      end
    
    Map.merge(existing_fish, new_fish)
  end

  defp send_viewer_setup(viewer_pid) do
    # Send initial setup commands to new viewer
    send(viewer_pid, {:aquarium_broadcast, "\x1b[?25l"})  # Hide cursor
    send(viewer_pid, {:aquarium_broadcast, "\x1b[?1000h"})  # Enable mouse
    send(viewer_pid, {:aquarium_broadcast, "\x1b[?1002h"})  # Enable mouse drag
    send(viewer_pid, {:aquarium_broadcast, "\x1b[2J"})  # Clear screen
    
    # Upload fish images
    fish_commands = SshAquarium.KittyGraphics.get_fish_images()
    Enum.each(fish_commands, fn command ->
      send(viewer_pid, {:aquarium_broadcast, command})
    end)
  end

  defp animate_fish(fish_map, terminal_config) do
    term_pixel_width = terminal_config.term_columns * terminal_config.cell_width
    term_pixel_height = terminal_config.term_rows * terminal_config.cell_height
    image_pixel_width = 64
    image_pixel_height = 36
    _image_cell_width = ceil(image_pixel_width / terminal_config.cell_width)
    _image_cell_height = ceil(image_pixel_height / terminal_config.cell_height)
    bubble_chars = ["°", "o", "O", "•"]
    bubble_speed = 4.0
    bobbing_amplitude = 12
    bobbing_frequency = 0.08
    bubble_spawn_rate = 0.001
    
    {new_fish, outputs} = 
      Enum.map_reduce(fish_map, [], fn {fish_id, fish}, acc_outputs ->
        # Update position
        px = fish.px + fish.dx
        py = fish.py + fish.dy
        
        # Wall bouncing
        {px, dx} = 
          cond do
            px + image_pixel_width > term_pixel_width ->
              {term_pixel_width - image_pixel_width, -abs(fish.dx)}
            px < 0 ->
              {0, abs(fish.dx)}
            true ->
              {px, fish.dx}
          end
        
        {py, dy} = 
          cond do
            py + image_pixel_height > term_pixel_height ->
              {term_pixel_height - image_pixel_height, -abs(fish.dy)}
            py < 0 ->
              {0, abs(fish.dy)}
            true ->
              {py, fish.dy}
          end
        
        # Bobbing
        bobbing_time = fish.bobbing_time + bobbing_frequency
        bobbing_offset = if rem(trunc(bobbing_time), 2) == 0, do: 0, else: bobbing_amplitude
        
        final_y = py + bobbing_offset
        _col = trunc(px / terminal_config.cell_width) + 1
        _x_offset = rem(trunc(px), terminal_config.cell_width)
        _row = trunc(final_y / terminal_config.cell_height) + 1
        _y_offset = rem(trunc(final_y), terminal_config.cell_height)
        
        # Spawn bubbles occasionally
        bubbles = 
          if :rand.uniform() < bubble_spawn_rate do
            new_bubble = %{
              x: px + image_pixel_width / 2,
              y: final_y - 2,
              char: Enum.random(bubble_chars),
              age: 0,
              prev_col: nil,
              prev_row: nil
            }
            [new_bubble | fish.bubbles]
          else
            fish.bubbles
          end
        
        # Update and filter bubbles
        {bubbles, bubble_output} = 
          Enum.reduce(bubbles, {[], ""}, fn bubble, {acc_bubbles, acc_output} ->
            # Clear previous bubble position
            clear_output = 
              if bubble.prev_col and bubble.prev_row do
                "\x1b[#{bubble.prev_row};#{bubble.prev_col}H "
              else
                ""
              end
            
            # Update bubble position
            new_y = bubble.y - bubble_speed
            new_age = bubble.age + 1
            
            # Check if bubble should be removed
            if new_y < 0 do
              {acc_bubbles, acc_output <> clear_output}
            else
              bubble_col = trunc(bubble.x / terminal_config.cell_width) + 1
              bubble_row = trunc(new_y / terminal_config.cell_height) + 1
              
              if bubble_col >= 1 and bubble_col <= terminal_config.term_columns and 
                 bubble_row >= 1 and bubble_row <= terminal_config.term_rows do
                new_bubble = %{bubble | 
                  y: new_y, 
                  age: new_age,
                  prev_col: bubble_col,
                  prev_row: bubble_row
                }
                render_output = "\x1b[#{bubble_row};#{bubble_col}H#{[bubble.char]}"
                {[new_bubble | acc_bubbles], acc_output <> clear_output <> render_output}
              else
                {acc_bubbles, acc_output <> clear_output}
              end
            end
          end)
        
        updated_fish = %{fish |
          px: px,
          py: py,
          dx: dx,
          dy: dy,
          bobbing_time: bobbing_time,
          bubbles: Enum.reverse(bubbles),
          placement_id: fish.placement_id
        }
        
        # Handle direction change if needed
        direction_change_output = SshAquarium.KittyGraphics.handle_direction_change(updated_fish, fish.dx, terminal_config)
        
        # Render fish image using Kitty graphics protocol
        fish_output = SshAquarium.KittyGraphics.render_fish(updated_fish, terminal_config)
        
        # Add fallback emoji fish for debugging
        emoji_col = trunc(updated_fish.px / terminal_config.cell_width) + 1
        emoji_row = trunc((updated_fish.py + bobbing_offset) / terminal_config.cell_height) + 1
        emoji = if updated_fish.dx > 0, do: "🐠", else: "🐟"
        emoji_output = "\x1b[#{emoji_row};#{emoji_col}H#{emoji}"
        
        frame_output = bubble_output <> direction_change_output <> fish_output
        
        {{fish_id, updated_fish}, [frame_output | acc_outputs]}
      end)
    
    output = outputs |> Enum.reverse() |> Enum.join()
    {Map.new(new_fish), output}
  end

  defp handle_mouse_click_internal(connection_id, mouse_data, terminal_config, fish_map) do
    <<"\x1b[M", button_byte, col_byte, row_byte, _rest::binary>> = mouse_data
    
    button = button_byte - 32
    mouse_col = col_byte - 32
    mouse_row = row_byte - 32
    
    Logger.debug("Mouse click: button=#{button}, col=#{mouse_col}, row=#{mouse_row}")
    
    # Only handle left clicks
    if button == 0 do
      mouse_x = (mouse_col - 1) * terminal_config.cell_width
      mouse_y = (mouse_row - 1) * terminal_config.cell_height
      
      # Check collision with fish (only allow clicking own fish)
      Enum.each(fish_map, fn {_fish_id, fish} ->
        if mouse_x >= fish.px and mouse_x <= fish.px + 64 and
           mouse_y >= fish.py and mouse_y <= fish.py + 36 do
          
          if fish.owner_id == connection_id do
            Logger.debug("Fish #{fish.id} clicked by owner #{connection_id}")
            # TODO: Implement fish interaction logic
          else
            Logger.debug("Connection #{connection_id} tried to click fish #{fish.id} owned by #{fish.owner_id}")
          end
        end
      end)
    end
  end

  defp create_poof_effect(fish, terminal_config) do
    if terminal_config do
      fish_col = trunc((fish.px + 32) / terminal_config.cell_width) + 1
      fish_row = trunc((fish.py + 18) / terminal_config.cell_height) + 1
      
      # Simple poof effect characters
      poof_positions = [
        {fish_col - 1, fish_row, "*"},
        {fish_col, fish_row, "💨"},
        {fish_col + 1, fish_row, "*"},
        {fish_col, fish_row - 1, "°"},
        {fish_col, fish_row + 1, "°"}
      ]
      
      # Show poof effect
      poof_output = 
        Enum.reduce(poof_positions, "", fn {col, row, char}, acc ->
          if col >= 1 and col <= terminal_config.term_columns and 
             row >= 1 and row <= terminal_config.term_rows do
            acc <> "\x1b[#{row};#{col}H#{char}"
          else
            acc
          end
        end)
      
      # TODO: Broadcast poof effect to viewers
      Logger.debug("Poof effect: #{inspect(poof_output)}")
      
      # Clear poof effect after delay
      spawn(fn ->
        :timer.sleep(1000)
        clear_output = 
          Enum.reduce(poof_positions, "", fn {col, row, _char}, acc ->
            if col >= 1 and col <= terminal_config.term_columns and 
               row >= 1 and row <= terminal_config.term_rows do
              acc <> "\x1b[#{row};#{col}H "
            else
              acc
            end
          end)
        # TODO: Broadcast clear effect to viewers
        Logger.debug("Poof effect cleared")
      end)
    end
  end

  defp broadcast_to_viewers(viewers, data) do
    Enum.each(viewers, fn {_connection_id, viewer_pid} ->
      send(viewer_pid, {:aquarium_broadcast, data})
    end)
  end
end