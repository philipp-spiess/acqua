defmodule SshAquarium.HealthServer do
  @moduledoc """
  Simple HTTP server for health checks on port 8080 using Plug.
  """

  use Plug.Router
  require Logger

  plug :match
  plug :dispatch

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def start_link(_) do
    port = System.get_env("HEALTH_PORT", "8080") |> String.to_integer()
    
    Logger.info("Starting health check server on port #{port}")
    
    Plug.Cowboy.http(__MODULE__, [], port: port)
  end

  get "/health" do
    response_body = Jason.encode!(%{status: "ok", service: "ssh_aquarium"})
    
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, response_body)
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end