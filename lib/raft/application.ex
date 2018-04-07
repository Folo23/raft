defmodule Raft.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Raft.RPC.Supervisor},
      Raft.Server.Supervisor,
    ]

    opts = [strategy: :one_for_one, name: Raft.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
