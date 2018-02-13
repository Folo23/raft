defmodule Raft.StateMachine do
  @moduledoc """
  This module provides a behaviour that can be implemented by clients to make
  use of the replicated log.

  TODO - Fill out the rest of this with detail and description.
  Maybe add a stack example.
  """

  @typedoc """
  The name of the node that is starting the state machine.
  """
  @type name() :: atom() | {atom(), atom()}

  @typedoc """
  The value to return to client after completing a read or write.
  """
  @type val() :: any()

  @typedoc """
  The state for the state machine.
  """
  @type state() :: any()

  @typedoc """
  The read or write command.
  """
  @type cmd() :: any()

  @doc """
  Called when the state machine is initialized.
  """
  @callback init(name()) :: state()

  @doc """
  Called whenever there has been a committed write command.
  """
  @callback handle_write(cmd(), state()) :: {val(), state()}

  @doc """
  Returns a unique name for the server.
  """
  @callback name :: atom()

  @doc """
  Called when the leader has established that they still have a majority and
  haven't been deposed as described in the raft paper section 8. While it is
  possible to change the state here it is HIGHLY discouraged. Changes during a
  read will NOT be persisted or replicated to other servers. Any mutations done
  here will be lost after a crash recovery or when starting a new server.
  """
  @callback handle_read(cmd(), state()) :: val() | {val(), state()}

  defmacro __using__(_) do
    quote location: :keep do
      @behaviour unquote(__MODULE__)

      def child_spec(opts), do: %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]},
        type: :supervisor,
      }

      def start_link(config) do
        Raft.Server.Supervisor.start_peer(name(), config)
      end

      def stop() do
        Raft.stop_node(name())
      end

      def write(msg, opts \\ []) do
        name()
        |> Raft.leader
        |> do_write(msg, opts)
      end

      def read(msg, opts \\ []) do
        name()
        |> Raft.leader
        |> do_read(msg, opts)
      end

      def name do
        raise "attempted to get name/0 but name wasn't set"
      end

      defp do_write(leader, msg, opts) do
        IO.inspect([leader, msg, opts], label: "Starting stuff")
        case Raft.write(leader, msg, opts) do
          {:ok, response} ->
            {:ok, response}
          {:error, {:redirect, leader}} ->
            do_write(leader, msg, opts)
          {:error, error} ->
            {:error, error}
        end
      end

      defp do_read(leader, msg, opts) do
        case Raft.read(leader, msg, opts) do
          {:ok, response} ->
            {:ok, response}
          {:error, {:redirect, leader}} ->
            do_read(leader, msg, opts)
          {:error, error} ->
            {:error, error}
        end
      end

      defoverridable [
        name: 0,
      ]
    end
  end
end
