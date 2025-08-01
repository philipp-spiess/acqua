defmodule SshAquarium.ShellHandler do
  @moduledoc """
  Custom SSH shell handler for the aquarium using esshd.
  """
  
  use Sshd.ShellHandler
  
  require Logger

  def on_shell(username, _ssh_publickey, ip_address, port_number) do
    Logger.info("Shell started for #{username} from #{inspect({ip_address, port_number})}")
    
    # Get the aquarium pid from the application
    aquarium_pid = case SshAquarium.Application.get_aquarium_pid() do
      {:ok, pid} -> pid
      {:error, _} -> 
        Logger.error("Could not get aquarium pid")
        nil
    end
    
    if aquarium_pid do
      # We need to start the shell loop first, then add viewer
      # Send a message to ourselves to add the viewer after loop starts
      send(self(), {:add_viewer_delayed, aquarium_pid, username})
      
      # Start the shell loop with a temporary connection_id
      shell_loop_init(aquarium_pid, username)
    else
      IO.puts("Error: Could not initialize aquarium")
    end
    
    :ok
  end

  def on_connect(username, ip_address, port_number, method) do
    Logger.debug("#{username} connecting from #{inspect({ip_address, port_number})} via #{method}")
    :ok
  end

  def on_disconnect(username, ip_address, port_number) do
    Logger.debug("#{username} disconnected from #{inspect({ip_address, port_number})}")
    :ok
  end

  defp shell_loop_init(aquarium_pid, username) do
    receive do
      {:add_viewer_delayed, aquarium_pid, username} ->
        # Now add as viewer - the shell loop is running and can receive broadcasts
        connection_id = SshAquarium.SharedAquarium.add_viewer(aquarium_pid, self())
        shell_loop(aquarium_pid, connection_id, username)
      
      other ->
        Logger.debug("Unexpected message during init: #{inspect(other)}")
        shell_loop_init(aquarium_pid, username)
    end
  end

  defp shell_loop(aquarium_pid, connection_id, username) do
    receive do
      {:aquarium_broadcast, data} ->
        # Debug log ALL broadcast messages
        Logger.info("SHELL_HANDLER: Received broadcast: #{inspect(String.slice(data, 0, 50))}...")
        # Debug log what we're sending to terminal
        if String.contains?(data, "\x1b[14t") do
          Logger.info(">>> SENDING TERMINAL QUERY TO CLIENT: #{inspect(data)}")
        end
        if String.contains?(data, "Hello") do
          Logger.info(">>> SENDING HELLO MESSAGE TO CLIENT: #{inspect(data)}")
        end
        IO.write(:stdio, data)
        shell_loop(aquarium_pid, connection_id, username)
      
      {:input, _from, data} ->
        # Log ALL input for debugging
        Logger.debug("<<< RECEIVED INPUT FROM CLIENT: #{inspect(data)}")
        # Handle user input
        case data do
          "\x03" -> # Ctrl+C
            cleanup_connection(aquarium_pid, connection_id)
            :ok
          
          # Handle terminal dimension response like Node.js
          <<"\x1b[4;", rest::binary>> ->
            Logger.info("Received terminal dimension response: #{inspect(rest)}")
            case parse_terminal_response(rest) do
              {pixel_height, pixel_width} ->
                # Calculate cell dimensions like Node.js
                term_columns = 80  # default, could get from terminal
                term_rows = 24     # default, could get from terminal  
                cell_width = round(pixel_width / term_columns)
                cell_height = round(pixel_height / term_rows)
                Logger.info("Terminal dimensions detected:")
                Logger.info("  - Pixel dimensions: #{pixel_width}x#{pixel_height} pixels")
                Logger.info("  - Terminal size: #{term_columns}x#{term_rows} chars")
                Logger.info("  - Cell size: #{cell_width}x#{cell_height} pixels per cell")
                SshAquarium.SharedAquarium.update_terminal_config(aquarium_pid, term_columns, term_rows, cell_width, cell_height)
              nil -> 
                Logger.error("Failed to parse terminal response: #{inspect(rest)}")
            end
            shell_loop(aquarium_pid, connection_id, username)
          
          <<"\x1b[M", _::binary>> = mouse_data when byte_size(mouse_data) >= 6 ->
            # Mouse click
            Logger.debug("Mouse event: #{inspect(mouse_data)}")
            SshAquarium.SharedAquarium.handle_mouse_click(aquarium_pid, connection_id, mouse_data)
            shell_loop(aquarium_pid, connection_id, username)
          
          _ ->
            # Ignore other input like Node.js does
            shell_loop(aquarium_pid, connection_id, username)
        end
      
      other ->
        Logger.debug("Shell received: #{inspect(other)}")
        shell_loop(aquarium_pid, connection_id, username)
    after
      30_000 ->
        # Keepalive
        shell_loop(aquarium_pid, connection_id, username)
    end
  end

  defp parse_terminal_response(data) do
    # Parse "height;widtht" format
    Logger.debug("Parsing terminal response data: #{inspect(data)}")
    case String.split(data, [";", "t"], parts: 3) do
      [height_str, width_str | _] ->
        Logger.debug("Split result: height=#{inspect(height_str)}, width=#{inspect(width_str)}")
        try do
          height = String.to_integer(height_str)
          width = String.to_integer(width_str)
          Logger.debug("Parsed dimensions: #{width}x#{height}")
          {height, width}
        rescue
          e -> 
            Logger.error("Error parsing integers: #{inspect(e)}")
            nil
        end
      parts -> 
        Logger.error("Unexpected split result: #{inspect(parts)}")
        nil
    end
  end

  defp cleanup_connection(aquarium_pid, connection_id) do
    Logger.info("Connection #{connection_id} disconnecting")
    SshAquarium.SharedAquarium.remove_viewer(aquarium_pid, connection_id)
    
    # Cleanup like Node.js
    IO.write("\x1b[?1000l")  # Disable mouse reporting
    IO.write("\x1b[?1002l")  # Disable mouse drag reporting  
    IO.write("\x1b[?25h")   # Show cursor
    IO.write("\x1b[2J")     # Clear screen
    IO.puts("\r\nAquarium session ended.\r\n")
  end
end