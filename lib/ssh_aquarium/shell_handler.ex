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
      # Add this connection as a viewer
      connection_id = SshAquarium.SharedAquarium.add_viewer(aquarium_pid, self())
      
      # Send welcome message
      IO.puts("Welcome to SSH Aquarium! 🐠")
      IO.puts("Setting up your aquarium...")
      
      # Setup fish images
      fish_commands = SshAquarium.KittyGraphics.get_fish_images()
      Enum.each(fish_commands, fn command ->
        IO.write(command)
      end)
      
      IO.puts("Fish images loaded!")
      
      # Start the shell loop
      shell_loop(aquarium_pid, connection_id, username)
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

  defp shell_loop(aquarium_pid, connection_id, username) do
    receive do
      {:aquarium_broadcast, data} ->
        IO.write(data)
        shell_loop(aquarium_pid, connection_id, username)
      
      {:input, data} ->
        # Handle user input
        case data do
          "\x03" -> # Ctrl+C
            cleanup_connection(aquarium_pid, connection_id)
            :ok
          
          <<"\x1b[M", _::binary>> = mouse_data when byte_size(mouse_data) >= 6 ->
            # Mouse click
            Logger.debug("Mouse event: #{inspect(mouse_data)}")
            SshAquarium.SharedAquarium.handle_mouse_click(aquarium_pid, connection_id, mouse_data)
            shell_loop(aquarium_pid, connection_id, username)
          
          _ ->
            IO.puts("You typed: #{inspect(data)}")
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

  defp cleanup_connection(aquarium_pid, connection_id) do
    Logger.info("Connection #{connection_id} disconnecting")
    SshAquarium.SharedAquarium.remove_viewer(aquarium_pid, connection_id)
    IO.puts("Aquarium session ended.")
  end
end