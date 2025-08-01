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
  @spec init(any()) :: {:ok, %{port: 1234}}
  def init(_opts) do
    Logger.info("ssh up: ssh -p #{@port} localhost")
    {:ok, %{port: @port}}
  end
end
