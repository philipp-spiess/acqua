defmodule SshAquarium.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the shared aquarium first
      {SshAquarium.SharedAquarium, []},
      # Start the SSH server
      SshAquarium.SshServer,
      # Health server for monitoring
      {SshAquarium.WwwServer, []}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SshAquarium.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} = result ->
        # Store the aquarium PID for the shell handler
        aquarium_pid = get_child_pid(pid, SshAquarium.SharedAquarium)
        :persistent_term.put({__MODULE__, :aquarium_pid}, aquarium_pid)
        result

      error ->
        error
    end
  end

  def get_aquarium_pid do
    case :persistent_term.get({__MODULE__, :aquarium_pid}, nil) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  defp get_child_pid(supervisor_pid, child_module) do
    supervisor_pid
    |> Supervisor.which_children()
    |> Enum.find(fn {id, _pid, _type, _modules} -> id == child_module end)
    |> elem(1)
  end
end
