defmodule SshAquarium do
  @moduledoc """
  SSH Aquarium - A collaborative fish aquarium accessible via SSH.
  
  This application creates an SSH server that displays an animated
  fish aquarium using the Kitty graphics protocol. Multiple users
  can connect simultaneously and interact with the fish.
  """

  def start do
    Application.start(:ssh_aquarium)
  end

  def stop do
    Application.stop(:ssh_aquarium)
  end
end
