defmodule SshAquarium.KittyGraphics do
  @moduledoc """
  Kitty Graphics Protocol implementation for displaying fish images.
  """

  require Logger

  @chunk_size 4096

  def kitty_command(payload) do
    "\x1b_G#{payload}\x1b\\"
  end

  def upload_image(image_data, image_id) do
    base64_data = Base.encode64(image_data)
    upload_image_base64(base64_data, image_id)
  end

  def upload_image_from_file(file_path, image_id) do
    case File.read(file_path) do
      {:ok, image_data} ->
        upload_image(image_data, image_id)
      {:error, reason} ->
        Logger.error("Failed to read image file #{file_path}: #{reason}")
        []
    end
  end

  defp upload_image_base64(base64_data, image_id) do
    chunks = chunk_string(base64_data, @chunk_size)
    
    chunks
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      is_first = index == 0
      more_chunks = index < length(chunks) - 1
      
      command = 
        if is_first do
          "a=t,f=100,i=#{image_id},m=#{if more_chunks, do: 1, else: 0},q=1"
        else
          "m=#{if more_chunks, do: 1, else: 0}"
        end
      
      kitty_command("#{command};#{chunk}")
    end)
  end

  def place_image(image_id, placement_id, opts \\ []) do
    col = Keyword.get(opts, :col, 1)
    row = Keyword.get(opts, :row, 1)
    width = Keyword.get(opts, :width, 1)
    height = Keyword.get(opts, :height, 1)
    x_offset = Keyword.get(opts, :x_offset, 0)
    y_offset = Keyword.get(opts, :y_offset, 0)
    
    # Move cursor to the cell where the top-left of the image should be anchored
    cursor_move = "\x1b[#{round(row)};#{round(col)}H"
    
    # Use C=1 to prevent the cursor from moving, which gives us full control
    place_command = kitty_command(
      "a=p,i=#{image_id},p=#{placement_id},c=#{width},r=#{height},C=1,X=#{round(x_offset)},Y=#{round(y_offset)},q=1"
    )
    
    cursor_move <> place_command
  end

  def delete_placement(image_id, placement_id) do
    kitty_command("a=d,d=i,i=#{image_id},p=#{placement_id},q=1")
  end

  def delete_placement_only(placement_id) do
    kitty_command("a=d,d=p,p=#{placement_id},q=1")
  end

  def clear_screen do
    "\x1b[2J"
  end

  # Helper function to chunk a string
  defp chunk_string(string, size) do
    string
    |> String.to_charlist()
    |> Enum.chunk_every(size)
    |> Enum.map(&List.to_string/1)
  end

  # Image management functions

  def get_fish_images(fish_path \\ "fish.png", fish_right_path \\ "fish-right.png") do
    fish_left_commands = upload_image_from_file(fish_path, 1)
    
    fish_right_commands = 
      if File.exists?(fish_right_path) do
        upload_image_from_file(fish_right_path, 2)
      else
        upload_image_from_file(fish_path, 2)  # Use left fish as fallback
      end
    
    fish_left_commands ++ fish_right_commands
  end

  def render_fish(fish, terminal_config) do
    image_pixel_width = 64
    image_pixel_height = 36
    image_cell_width = ceil(image_pixel_width / terminal_config.cell_width)
    image_cell_height = ceil(image_pixel_height / terminal_config.cell_height)
    
    # Determine which direction the fish is facing
    current_image_id = if fish.dx > 0, do: 2, else: 1  # 2 = right, 1 = left
    
    # Calculate position
    col = trunc(fish.px / terminal_config.cell_width) + 1
    x_offset = rem(trunc(fish.px), terminal_config.cell_width)
    row = trunc(fish.py / terminal_config.cell_height) + 1
    y_offset = rem(trunc(fish.py), terminal_config.cell_height)
    
    place_image(current_image_id, fish.placement_id, [
      col: col,
      row: row,
      width: image_cell_width,
      height: image_cell_height,
      x_offset: x_offset,
      y_offset: y_offset
    ])
  end

  def handle_direction_change(fish, previous_dx, terminal_config) do
    # Check if direction changed
    current_facing_right = fish.dx > 0
    previous_facing_right = previous_dx > 0
    
    if current_facing_right != previous_facing_right do
      # Direction changed, delete previous image placement
      previous_image_id = if previous_facing_right, do: 2, else: 1
      delete_placement(previous_image_id, fish.placement_id)
    else
      ""
    end
  end
end