defmodule Sshd.Application do
  # See http://elixir-lang.org/docs/stable/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    # Define workers and child supervisors to be supervised
    children = [
      # Starts a worker by calling: Sshd.Worker.start_link(arg1, arg2, arg3)
      # {Sshd.Worker, [arg1, arg2, arg3]},
      %{
        id: Sshd.Server,
        start: {Sshd.Server, :start_link, []}
      },
      %{
        id: Sshd.Sessions,
        start: {Sshd.Sessions, :start_link, []}
      }
    ]

    # See http://elixir-lang.org/docs/stable/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Sshd.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
