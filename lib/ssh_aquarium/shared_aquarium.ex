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
  @animation_interval 17  # ~60 FPS (16.66ms rounded up)

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

  def update_terminal_config(pid, term_columns, term_rows, cell_width, cell_height) do
    GenServer.cast(pid, {:update_terminal_config, term_columns, term_rows, cell_width, cell_height})
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
    
    # If this is the first viewer, detect terminal and wait for response before starting
    state = 
      if MapSet.size(state.viewers) == 0 do
        Logger.info("First viewer - detecting terminal and starting animation")
        
        # TEST: Send a simple hello message first
        Logger.info("TEST: Sending hello message to verify communication")
        send(viewer_pid, {:aquarium_broadcast, "Hello from Elixir SSH Aquarium!\r\n"})
        send(viewer_pid, {:aquarium_broadcast, "If you see this, messages are working.\r\n"})
        
        # Send initial setup like Node.js does before detection
        send(viewer_pid, {:aquarium_broadcast, "\x1b[?25l"})    # Hide cursor
        send(viewer_pid, {:aquarium_broadcast, "\x1b[?1000h"})  # Enable mouse click reporting
        send(viewer_pid, {:aquarium_broadcast, "\x1b[?1002h"})  # Enable mouse drag reporting
        send(viewer_pid, {:aquarium_broadcast, "\x1b[2J"})      # Clear screen
        
        # Upload images like Node.js
        fish_commands = SshAquarium.KittyGraphics.get_fish_images()
        Enum.each(fish_commands, fn command ->
          send(viewer_pid, {:aquarium_broadcast, command})
        end)
        
        # Send terminal detection query like Node.js does
        Logger.info("Sending terminal detection query to first viewer")
        send(viewer_pid, {:aquarium_broadcast, "\x1b[14t"})
        
        # Set a timeout like Node.js (2 seconds)
        Logger.info("Setting 2-second timeout for terminal detection")
        Process.send_after(self(), {:terminal_detection_timeout, connection_id}, 2000)
        
        # Set up state to wait for terminal detection
        %{state | 
          terminal_config: :detecting,  # Mark as detecting
          fish_counter: 0  # Will be set when terminal is detected
        }
      else
        # Add fish for new connection (like Node.js additional viewers)
        if is_map(state.terminal_config) do
          Logger.info("Adding 100 fish and viewer to existing aquarium")
          
          # Add fish for this connection
          fish = add_fish_for_connection(state.fish, state.terminal_config, connection_id, @fish_per_connection, state.fish_counter)
          
          # Send complete setup to new viewer (like Node.js)
          send_viewer_setup(viewer_pid, state.terminal_config)
          
          %{state | 
            fish: fish,
            fish_counter: state.fish_counter + @fish_per_connection
          }
        else
          # Terminal still detecting, add viewer but no fish yet
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
      create_poof_effect(fish, state.terminal_config, new_viewers)
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
    if is_map(state.terminal_config) do
      new_fish = handle_mouse_click_internal(connection_id, mouse_data, state.terminal_config, state.fish)
      {:noreply, %{state | fish: new_fish}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:update_terminal_config, term_columns, term_rows, cell_width, cell_height}, state) do
    cond do
      state.terminal_config == :detecting ->
        # First time detection - set up aquarium like Node.js
        Logger.info("First terminal detection received! Setting up aquarium...")
        Logger.info("Terminal configuration:")
        Logger.info("  - Columns: #{term_columns}")
        Logger.info("  - Rows: #{term_rows}")
        Logger.info("  - Cell width: #{cell_width} pixels")
        Logger.info("  - Cell height: #{cell_height} pixels")
        Logger.info("  - Total canvas: #{term_columns * cell_width}x#{term_rows * cell_height} pixels")
        
        terminal_config = %{
          term_columns: term_columns,
          term_rows: term_rows,
          cell_width: cell_width,
          cell_height: cell_height
        }
        
        # Add fish for all existing connections (like Node.js does)
        fish = 
          state.viewers
          |> MapSet.to_list()
          |> Enum.with_index(1)
          |> Enum.reduce(%{}, fn {{connection_id, viewer_pid}, index}, acc ->
            # Setup viewer (like Node.js does for all viewers)
            send_viewer_setup(viewer_pid, terminal_config)
            # Add 100 fish for each connection
            add_fish_for_connection(acc, terminal_config, connection_id, @fish_per_connection, (index - 1) * @fish_per_connection)
          end)
        
        viewer_count = MapSet.size(state.viewers)
        
        # Start animation like Node.js
        {:ok, timer_ref} = :timer.send_interval(@animation_interval, self(), :animate)
        send(self(), :animate)
        
        {:noreply, %{state | 
          terminal_config: terminal_config,
          fish: fish,
          animation_timer: timer_ref,
          fish_counter: viewer_count * @fish_per_connection
        }}
      
      is_map(state.terminal_config) ->
        # Update existing config
        updated_config = %{state.terminal_config |
          term_columns: term_columns,
          term_rows: term_rows,
          cell_width: cell_width,
          cell_height: cell_height
        }
        Logger.info("Updated terminal config: #{cell_width}x#{cell_height} pixels per cell")
        {:noreply, %{state | terminal_config: updated_config}}
      
      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:animate, state) do
    if MapSet.size(state.viewers) > 0 and is_map(state.terminal_config) do
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

  @impl true
  def handle_info({:terminal_detection_timeout, _connection_id}, state) do
    if state.terminal_config == :detecting do
      Logger.warn("Terminal detection timeout! Using fallback dimensions...")
      Logger.warn("Fallback config: 80x24 chars, 8x16 pixels per cell")
      # Use fallback dimensions like Node.js
      handle_cast({:update_terminal_config, 80, 24, 8, 16}, state)
    else
      Logger.debug("Terminal detection timeout received but config already set")
      {:noreply, state}
    end
  end

  # Helper Functions


  defp add_fish_for_connection(existing_fish, terminal_config, connection_id, count, fish_counter) do
    term_pixel_width = terminal_config.term_columns * terminal_config.cell_width
    term_pixel_height = terminal_config.term_rows * terminal_config.cell_height
    
    Logger.info("Adding #{count} fish for connection #{connection_id}")
    Logger.info("Canvas dimensions: #{term_pixel_width}x#{term_pixel_height} pixels")
    Logger.info("Fish image size: 64x36 pixels")
    Logger.info("Valid fish X range: 0 to #{term_pixel_width - 64}")
    Logger.info("Valid fish Y range: 0 to #{term_pixel_height - 36}")
    
    new_fish = 
      for i <- 1..count, into: %{} do
        fish_id = fish_counter + i
        px = :rand.uniform() * (term_pixel_width - 64)
        py = :rand.uniform() * (term_pixel_height - 36)
        
        # Log first 5 fish positions for debugging
        if i <= 5 do
          Logger.debug("Fish ##{fish_id} initial position: (#{Float.round(px, 2)}, #{Float.round(py, 2)})")
        end
        
        fish = %{
          id: fish_id,
          owner_id: connection_id,
          px: px,
          py: py,
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

  defp send_viewer_setup(viewer_pid, _terminal_config) do
    # TEMPORARY: Simple test message instead of fish setup
    send(viewer_pid, {:aquarium_broadcast, "Hello! SSH connection working!\r\n"})
    send(viewer_pid, {:aquarium_broadcast, "You should see this text message.\r\n"})
    
    # # Send initial setup commands to new viewer (exactly like Node.js)
    # send(viewer_pid, {:aquarium_broadcast, "\x1b[?25l"})    # Hide cursor
    # send(viewer_pid, {:aquarium_broadcast, "\x1b[?1000h"})  # Enable mouse click reporting
    # send(viewer_pid, {:aquarium_broadcast, "\x1b[?1002h"})  # Enable mouse drag reporting
    # send(viewer_pid, {:aquarium_broadcast, "\x1b[2J"})     # Clear screen
    
    # # Upload fish images (exactly like Node.js)
    # fish_commands = SshAquarium.KittyGraphics.get_fish_images()
    # Enum.each(fish_commands, fn command ->
    #   send(viewer_pid, {:aquarium_broadcast, command})
    # end)
    
    Logger.debug("Setup completed for new viewer")
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
              if bubble.prev_col != nil and bubble.prev_row != nil do
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
        
        # No emoji fallback - match Node.js exactly
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
      
      Logger.debug("Click position in pixels: (#{mouse_x}, #{mouse_y})")
      
      bubble_chars = ["°", "o", "O", "•"]
      
      # Update fish map with any clicked fish and track collisions
      {updated_fish_map, found_collision} = 
        Enum.reduce(fish_map, {fish_map, false}, fn {fish_id, fish}, {acc, collision_found} ->
          Logger.debug("Checking fish ##{fish.id} at (#{fish.px}, #{fish.py}) owned by #{fish.owner_id}")
          if mouse_x >= fish.px and mouse_x <= fish.px + 64 and
             mouse_y >= fish.py and mouse_y <= fish.py + 36 do
            
            Logger.debug("HIT: Fish ##{fish.id} collision detected")
            
            if fish.owner_id == connection_id do
              Logger.debug("ALLOWED: Connection #{connection_id} clicking their own fish ##{fish.id}")
              
              # Spawn bubbles when clicked (like Node.js)
              new_bubbles = for i <- 0..2 do
                %{
                  x: fish.px + 32 + (:rand.uniform() - 0.5) * 20, # slight random spread
                  y: fish.py - 2 - i * 5, # staggered vertically
                  char: Enum.random(bubble_chars),
                  age: 0,
                  prev_col: nil,
                  prev_row: nil
                }
              end
              
              # Random direction change (like Node.js)
              angles = [90, 180, 260]
              random_angle = Enum.random(angles)
              radians = (random_angle * :math.pi()) / 180
              
              # Rotate velocity vector
              new_dx = fish.dx * :math.cos(radians) - fish.dy * :math.sin(radians)
              new_dy = fish.dx * :math.sin(radians) + fish.dy * :math.cos(radians)
              
              # Update fish state
              updated_fish = %{fish | 
                dx: new_dx, 
                dy: new_dy, 
                bubbles: new_bubbles ++ fish.bubbles
              }
              
              Logger.debug("Fish ##{fish.id} clicked - direction changed and bubbles spawned")
              {Map.put(acc, fish_id, updated_fish), true}
            else
              Logger.debug("BLOCKED: Connection #{connection_id} tried to click fish ##{fish.id} owned by #{fish.owner_id}")
              {acc, true}
            end
          else
            {acc, collision_found}
          end
        end)
      
      if not found_collision do
        Logger.debug("No collision found for click at (#{mouse_x}, #{mouse_y})")
      end
      
      updated_fish_map
    else
      fish_map
    end
  end

  defp create_poof_effect(fish, terminal_config, viewers) do
    if terminal_config do
      fish_col = trunc((fish.px + 32) / terminal_config.cell_width) + 1
      fish_row = trunc((fish.py + 18) / terminal_config.cell_height) + 1
      
      # Simple poof effect characters (exactly like Node.js)
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
      
      # Broadcast poof effect to all viewers (like Node.js)
      if poof_output != "" do
        broadcast_to_viewers(viewers, poof_output)
        Logger.debug("Poof effect broadcasted to #{MapSet.size(viewers)} viewers")
      end
      
      # Clear poof effect after delay (like Node.js - 1000ms)
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
        # Broadcast clear effect to viewers (like Node.js)
        if clear_output != "" do
          broadcast_to_viewers(viewers, clear_output)
          Logger.debug("Poof effect cleared")
        end
      end)
    end
  end

  defp broadcast_to_viewers(viewers, data) do
    Enum.each(viewers, fn {_connection_id, viewer_pid} ->
      send(viewer_pid, {:aquarium_broadcast, data})
    end)
  end
end