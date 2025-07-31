defmodule SshAquarium.SshServer do
  @moduledoc """
  SSH server configuration for the fish aquarium using esshd.
  """

  use GenServer
  require Logger

  @port 1234

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("SSH server will start on port #{@port}")
    Logger.info("Connect with: ssh -p #{@port} localhost")
    {:ok, %{port: @port}}
  end
end