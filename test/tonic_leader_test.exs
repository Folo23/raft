defmodule TonicLeaderTest do
  use ExUnit.Case
  doctest TonicLeader

  alias TonicLeader.{Config, Server}

  # defmodule StackTestFSM do
  #   @behaviour TonicLeader.FSM

  #   def init(_) do
  #     []
  #   end

  #   def handle_query(stack) do
  #     {:reply, {:ok, stack}, stack}
  #   end

  #   def handle_apply({:enqueue, item}, stack) do
  #     {:reply, :ok, [item | stack]}
  #   end

  #   def handle_apply(:dequeue, [item | stack]) do
  #     {:reply, {:ok, item}, stack}
  #   end

  #   def handle_apply(:dequeue, stack) do
  #     {:reply, {:error, :empty}, stack}
  #   end
  # end

  setup do
    :tonic_leader
    |> Application.app_dir
    |> File.cd!(fn ->
      File.ls!()
      |> Enum.filter(fn file -> file =~ ~r/.tonic$/ end)
      |> Enum.map(&Path.relative_to_cwd/1)
      |> Enum.map(&File.rm_rf!/1)
    end)

    :ok
  end

  test "starting a cluster" do
    # Start each node individually with no configuration. Each node will
    # come up as a follower and remain there since they have no known
    # configuration yet.
    {:ok, _s1} = TonicLeader.start_node(:s1, %Config{})
    {:ok, _s2} = TonicLeader.start_node(:s2, %Config{})
    {:ok, _s3} = TonicLeader.start_node(:s3, %Config{})

    # Tell a server about other nodes
    nodes = [:s1, :s2, :s3]
    {:error, :peers_not_responding} = TonicLeader.set_configuration(:s1, nodes)

    IO.puts "Made it past setting config"

    # Ensure that s1 has been elected leader which means our configuration has
    # been shared throughout the cluster.
    _ = wait_for_election(nodes)

    assert TonicLeader.leader(:s1) == :s1
    assert TonicLeader.leader(:s2) == :s1
    assert TonicLeader.leader(:s3) == :s1
  end

  # describe "bootstrap/2" do
  #   test "starts a new cluster" do
  #     configuration = %Configuration{
  #       old_servers: [
  #         Configuration.voter(:s1, node()),
  #         Configuration.voter(:s2, node()),
  #         Configuration.voter(:s3, node()),
  #       ],
  #       index: 1,
  #     }
  #     {:ok, s1} = TonicLeader.bootstrap(%Config{name: :s1}, configuration)
  #     {:ok, s2} = TonicLeader.bootstrap(%Config{name: :s2}, configuration)
  #     {:ok, s3} = TonicLeader.bootstrap(%Config{name: :s3}, configuration)

  #     assert TonicLeader.Server.status(s1)[:configuration] == configuration
  #     assert TonicLeader.Server.status(s2)[:configuration] == configuration
  #     assert TonicLeader.Server.status(s3)[:configuration] == configuration

  #     assert TonicLeader.Server.leader(s1) == :none

  #     leader = wait_for_election([s1, s2, s3])

  #     assert TonicLeader.Server.leader(s1) == leader
  #     assert TonicLeader.Server.leader(s2) == leader
  #     assert TonicLeader.Server.leader(s3) == leader
  #   end
  # end

  #test "log replication with 3 servers" do
  #  base_config = %Config{
  #    state_machine: StackTestFSM,
  #    name: :none,
  #  }
  #  configuration = %Configuration{
  #    old_servers: [
  #      Configuration.voter(:s1, node()),
  #      Configuration.voter(:s2, node()),
  #      Configuration.voter(:s3, node()),
  #    ],
  #    index: 1,
  #  }
  #  {:ok, s1} = TonicLeader.bootstrap(%Config{base_config | name: :s1}, configuration)
  #  {:ok, s2} = TonicLeader.bootstrap(%Config{base_config | name: :s2}, configuration)
  #  {:ok, s3} = TonicLeader.bootstrap(%Config{base_config | name: :s3}, configuration)

  #  leader = wait_for_election([s1, s2, s3])

  #  assert :ok          = TonicLeader.Server.apply(leader, {:enqueue, 1})
  #  assert :ok          = TonicLeader.Server.apply(leader, {:enqueue, 2})
  #  assert {:ok, 2}     = TonicLeader.Server.apply(leader, :dequeue)
  #  assert :ok          = TonicLeader.Server.apply(leader, {:enqueue, 3})
  #  assert {:ok, [3,1]} = TonicLeader.Server.query(leader)

  #  # Ensure that the messages are replicated to all servers
  #  #
  #  # Ensure that the fsms all have logs applied
  #end

  # test "leader failure" do
    # cluster = make_cluster(3)
    # leader = leader(cluster)
    # :ok = TonicLeader.Server.apply(leader, {:enqueue, 1})
    # wait_for_replication(1)

    # Disconnect the leader from the cluster
    # current_term = TonicLeader.Server.current_term(leader)
    # disconnect(leader)

    # Wait until a new leader is elected
    #
    # leader = leader(cluster)

    # Ensure the current term is greater
    #
    # Apply should not work on old leader
    #
    # Apply should work on new leader
    #
    # Reconnect the leader
    #
    # Ensure that the fsms all have the same content
    #
    # Ensure that there are 2 entries applied to all fsms
  # end

  def wait_for_election(servers) do
    servers
    |> Enum.map(&Server.status/1)
    |> IO.inspect(label: "Current states")
    |> Enum.find(& &1.current_state == :leader)
    |> case do
      nil ->
        :timer.sleep(200)
        wait_for_election(servers)
      leader ->
        leader.name
    end
  end
end

