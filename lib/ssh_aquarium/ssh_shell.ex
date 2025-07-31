defmodule SshAquarium.SshShell do
  @moduledoc """
  SSH shell implementation that handles individual SSH connections.
  """

  require Logger

  def start_shell(aquarium_pid, user, peer_addr) do
    Logger.info("User #{user} connected from #{inspect(peer_addr)}")
    shell_loop(aquarium_pid, user, peer_addr)
  end

  defp shell_loop(aquarium_pid, user, peer_addr) do
    receive do
      {ssh_cm, channel_id, {:shell, false}} ->
        Logger.debug("Shell request received for user #{user}")
        # Reply to shell request
        :ssh_connection.reply_request(ssh_cm, channel_id, :success, true)
        
        # Send immediate test output
        :ssh_connection.send(ssh_cm, channel_id, "TEST: Shell started!\r\n")
        :ssh_connection.send(ssh_cm, channel_id, "User: #{user}\r\n")
        :ssh_connection.send(ssh_cm, channel_id, "Peer: #{inspect(peer_addr)}\r\n")
        
        connection_id = SshAquarium.SharedAquarium.add_viewer(aquarium_pid, self())
        send_initial_setup(ssh_cm, channel_id)
        main_shell_loop(ssh_cm, channel_id, aquarium_pid, connection_id, user)
      
      other ->
        Logger.debug("Shell received unexpected init message: #{inspect(other)}")
        shell_loop(aquarium_pid, user, peer_addr)
    end
  end

  defp main_shell_loop(ssh_cm, channel_id, aquarium_pid, connection_id, user) do
    # Send a test message every second
    :ssh_connection.send(ssh_cm, channel_id, ".")
    
    receive do
      {^ssh_cm, ^channel_id, {:data, 0, data}} ->
        :ssh_connection.send(ssh_cm, channel_id, "You typed: #{inspect(data)}\r\n")
        handle_user_input(ssh_cm, channel_id, aquarium_pid, connection_id, data)
        main_shell_loop(ssh_cm, channel_id, aquarium_pid, connection_id, user)
      
      {:aquarium_broadcast, data} ->
        :ssh_connection.send(ssh_cm, channel_id, "[BROADCAST]: #{byte_size(data)} bytes\r\n")
        :ssh_connection.send(ssh_cm, channel_id, data)
        main_shell_loop(ssh_cm, channel_id, aquarium_pid, connection_id, user)
      
      {^ssh_cm, ^channel_id, {:eof, 0}} ->
        cleanup_connection(ssh_cm, channel_id, aquarium_pid, connection_id)
      
      {^ssh_cm, ^channel_id, {:closed, 0}} ->
        cleanup_connection(ssh_cm, channel_id, aquarium_pid, connection_id)
      
      other ->
        Logger.debug("Shell received: #{inspect(other)}")
        main_shell_loop(ssh_cm, channel_id, aquarium_pid, connection_id, user)
    after
      30_000 ->
        main_shell_loop(ssh_cm, channel_id, aquarium_pid, connection_id, user)
    end
  end

  defp send_initial_setup(ssh_cm, channel_id) do
    # Send welcome message first
    :ssh_connection.send(ssh_cm, channel_id, "Welcome to SSH Aquarium! 🐠\r\n")
    :ssh_connection.send(ssh_cm, channel_id, "Setting up your aquarium...\r\n")
    
    :ssh_connection.send(ssh_cm, channel_id, "\x1b[?25l")
    :ssh_connection.send(ssh_cm, channel_id, "\x1b[?1000h")
    :ssh_connection.send(ssh_cm, channel_id, "\x1b[?1002h")
    :ssh_connection.send(ssh_cm, channel_id, "\x1b[2J")
    
    # Show loading message
    :ssh_connection.send(ssh_cm, channel_id, "\x1b[1;1HLoading fish images...")
    setup_fish_images(ssh_cm, channel_id)
    :ssh_connection.send(ssh_cm, channel_id, "\x1b[2;1HFish images loaded!")
  end

  defp setup_fish_images(ssh_cm, channel_id) do
    fish_commands = SshAquarium.KittyGraphics.get_fish_images()
    Enum.each(fish_commands, fn command ->
      :ssh_connection.send(ssh_cm, channel_id, command)
    end)
  end

  defp handle_user_input(ssh_cm, channel_id, aquarium_pid, connection_id, data) do
    case data do
      "\x03" ->
        cleanup_connection(ssh_cm, channel_id, aquarium_pid, connection_id)
        :ssh_connection.close(ssh_cm, channel_id)
      
      <<"\x1b[M", _::binary>> = mouse_data when byte_size(mouse_data) >= 6 ->
        Logger.debug("Mouse event from connection #{connection_id}: #{inspect(mouse_data)}")
        SshAquarium.SharedAquarium.handle_mouse_click(aquarium_pid, connection_id, mouse_data)
      
      _other ->
        Logger.debug("Input from connection #{connection_id}: #{inspect(data)}")
    end
  end

  defp cleanup_connection(ssh_cm, channel_id, aquarium_pid, connection_id) do
    Logger.info("Connection #{connection_id} disconnecting")
    SshAquarium.SharedAquarium.remove_viewer(aquarium_pid, connection_id)
    :ssh_connection.send(ssh_cm, channel_id, "\x1b[?1000l")
    :ssh_connection.send(ssh_cm, channel_id, "\x1b[?1002l")
    :ssh_connection.send(ssh_cm, channel_id, "\x1b[?25h")
    :ssh_connection.send(ssh_cm, channel_id, "\x1b[2J")
    :ssh_connection.send(ssh_cm, channel_id, "\r\nAquarium session ended.\r\n")
  end
end