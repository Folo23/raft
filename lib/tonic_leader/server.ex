defmodule TonicLeader.Server do
  use GenStateMachine, callback_mode: :state_functions

  alias TonicLeader.{RPC, Log, LogStore, Config, Configuration}
  alias TonicLeader.RPC.{
    AppendEntriesReq,
    AppendEntriesResp,
    RequestVoteReq,
    RequestVoteResp,
  }
  alias TonicLeader.Server.State

  require Logger

  @type state :: :leader
               | :follower
               | :candidate

  @type members :: %{required(atom()) => pid()}

  @typep status :: %{
    members: members(),
    current_state: state()
  }

  # @current_term "CurrentTerm"
  # @voted_for "VotedFor"
  @last_vote_term "LastVoteTerm"
  @last_vote_cand "LastVoteCand"

  def child_spec(opts), do: %{
    id: __MODULE__,
    start: {__MODULE__, :start_link, [opts]},
    restart: :permanent,
    shutdown: 5000,
    type: :worker
  }

  def start_link(name, config) do
    GenStateMachine.start_link(__MODULE__, {:follower, name, config}, name: name)
  end
  # def start_link(opts) do
  #   GenStateMachine.start_link(__MODULE__, {:follower, Config.new(opts)})
  # end
  #
  def set_configuration(peer, configuration) do
    GenStateMachine.call(peer, {:set_configuration, configuration})
  end

  def get(sm, key) do
    GenStateMachine.call(sm, {:get, key})
  end

  def put(sm, key, value) do
    GenStateMachine.call(sm, {:put, key, value})
  end

  @doc """
  Applies a new log to the application state machine. This is done in a highly
  consistent manor. This must be called on the leader or it will fail.
  """
  # @spec apply(server(), term()) :: :ok | {:error, :timeout} | {:error, :not_leader}

  def apply(sm, msg) do
    GenStateMachine.call(sm, {:apply, msg})
  end

  def query(sm) do
    GenStateMachine.call(sm, :query)
  end

  @doc """
  Returns the name of the server that is believed to be the leader. This
  is not a consistent operation and during a network partition its possible that
  the server doesn't know who the latest elected leader is. This function should
  be used for testing and debugging purposes only.
  """
  def leader(server) do
    status = GenStateMachine.call(server, :status)
    status[:leader]
  end

  @doc """
  Adds a new member to the cluster. The member is added as a follower.
  If this is a new server then the new member will be passed a snapshot
  in order to build the log locally. The new member will be unavailable for
  voting in a term until its persisted all of the log entries.
  """
  def add_voter(server, name, address) do
    change = %{
      command: :add_voter,
      name: name,
      address: address,
    }

    GenStateMachine.call(server, {:config_change, change})
  end

  @spec status(pid()) :: status()
  def status(sm) do
    GenStateMachine.call(sm, :status)
  end

  @doc """
  TODO: Implement this workflow.
  * Pull logs out of storage
  * Pull current term out of storage
  * Set a new election timeout
  * Find the most recent config change (start from most recent snapshot if we have one)
  * Restore state:
  * - set last index
  * - set last_log
  * - set current term
  * - set the configuration
  """
  def init({:follower, name, config}) do
    Logger.info("Starting #{name}")
    {:ok, log_store} = LogStore.open(Config.db_path(name, config))

    Logger.info("Restoring old state", metadata: name)

    metadata            = LogStore.get_metadata(log_store)
    current_term        = metadata.term
    # last_index          = LogStore.last_index(log_store)
    # start_index         = 0 # TODO: This should be the index of the last snapshot if there is one
    # logs                = LogStore.slice(log_store, start_index..last_index)
    # configuration       = Configuration.restore(logs)
    configuration       = LogStore.get_config(log_store)
    state               = State.new(config, log_store, 0, current_term, configuration)
    state               = reset_timeout(state)
    state = %{state | me: name}

    Logger.info("State has been restored", [server: config.name])
    {:ok, :follower, state}
  end

  def has_data?(log_store) do
    LogStore.last_index(log_store) > 0
  end

  #
  # Leader callbacks
  #

  defp send_append_entries(%{log_store: store, followers: followers}=state) do
    followers
    |> Enum.map(send_entry(state))
    |> RPC.broadcast
  end

  def leader(:info, :timeout, state) do
    Logger.debug("#{state.me}: Sending heartbeats")
    send_append_entries(state)
    {:next_state, :leader, reset_timeout(heartbeat_timeout(), state)}
  end

  # We're out of date so step down
  def leader(:cast, %AppendEntriesResp{success: false, term: term},
                    %{current_term: current_term}=state) when term > current_term do
    Logger.warn("#{state.me}: Out of date, stepping down as leader")
    {:next_state, :follower, %{state | current_term: term}, []}
  end

  # Follower needs to be caught up so decrement the followers next index.
  # The next time a heartbeat times out we will send them all of the entries
  # and hopefully catch them up. If they aren't then we try again.
  def leader(:cast, %AppendEntriesResp{success: false, from: from}=resp, state) do
    Logger.debug("#{state.me}: Follower #{from} is out of date. Decrementing index")
    next_index = Map.update(state.next_index, from, & &1-1)
    {:next_state, :leader, %{state | next_index: next_index}}
  end

  # Stale reply so ignore it
  def leader(:cast, %AppendEntriesResp{success: true, term: term}=resp,
                    %{current_term: current_term}=state) when current_term > term do
    Logger.debug("#{state.me}: Stale reply")
    {:keep_state_and_data, []}
  end

  # Succeeded to replicate to follower
  def leader(:cast, %AppendEntriesResp{success: true, from: from, index: index}=resp, state) do
    Logger.debug("#{state.me}: Successfully replicated index #{index} to #{from}")
    match_index = Map.put(state.match_index, from, index)
    next_index = Map.put(state.next_index, from, index+1)
    state = %{state | match_index: match_index, next_index: next_index}
    state = maybe_commit_logs(state)

    IO.inspect(state, label: "New state after replication")
    {:next_state, :leader, state}
  end

  def leader(msg, event, data) do
    handle_event(msg, event, :leader, data)
  end

  # TODO - pull this apart so it just returns the new commit index and we can
  # take actions in the leader callback
  def maybe_commit_logs(state) do
    commit_index = Configuration.quorum_max(state.configuration, state.match_index)
    IO.inspect(commit_index, label: "commit index")
    cond do
      commit_index > state.commit_index and safe_to_commit?(commit_index, state) ->
        Logger.debug("Committing to index #{commit_index}")
        commit_entries(commit_index, state)
      true ->
        Logger.debug("#{state.me}: Not committing since there isn't a quorum yet.")
        state
    end
  end

  def safe_to_commit?(index, %{current_term: term, log_store: log_store}) do
    with {:ok, log} <- LogStore.get_log(log_store, index) do
      log.term == term
    else
      _ ->
        false
    end
  end

  #
  # Follower callbacks
  #

  def follower(:info, :timeout, %{configuration: config}=state) do
    case Configuration.has_vote?(config) do
      true ->
        Logger.debug("#{state.me}: Becoming candidate")
        new_state = become_candidate(state)
        {:next_state, :candidate, new_state}
      false ->
        state = reset_timeout(state)
        state = %{state | leader: :none}
        {:next_state, :follower, state}
    end
  end

  # We can set the configuration if we're in follower state and we have no
  # configuration is empty (which means the log is empty). This is so we can
  # bootstrap a new server.
  def follower({:call, from}, {:set_configuration, {id, peers}}, %{configuration: %{state: :none}}=state) do
    Logger.debug("Setting initial configuration on #{state.me}")
    case Enum.member?(peers, state.me) do
      true ->
        config = Configuration.reconfig(state.configuration, peers)
        followers = Configuration.followers(config, state.me)
        new_state = %{state |
          followers: followers,
          configuration: config,
          init_config: {id, from}
        }
        {:next_state, :candidate, new_state}

      false ->
        rpy = {:reply, from, {:error, :must_be_in_consesus_group}}
        {:keep_state_and_data, [rpy]}
    end
  end

  def follower({:call, from}, {:set_configuration, _change}, _state) do
    Logger.warn("Cannot set_configuration on a follower that has a configuration")
    {:keep_state_and_data, [{:reply, from, {:error, :not_leader}}]}
  end

  # Leader has a lower term then us
  # def follower(:cast, %AppendEntriesReq{term: term},
  def follower({:call, from}, %AppendEntriesReq{term: term},
               %{current_term: current_term}=state) when current_term > term do
    Logger.debug("Rejected append entries from leader with a lower term")

    resp = %AppendEntriesResp{from: state.me, term: current_term, success: false}
    rpy = {:reply, from, resp}
    {:keep_state_and_data, [rpy]}
  end

  # def follower(:cast, %AppendEntriesReq{}=req, state) do
  def follower({:call, from}, %AppendEntriesReq{}=req, state) do
    state = reset_timeout(state)
    state = set_term(req.term, state)
    # When bumping the term we also need to undefine who we voted for this term
    resp = %AppendEntriesResp{success: false, term: state.current_term, from: state.me}
    if consistent?(req, state) do
      Logger.debug(fn -> "#{state.me}: Log is consistent. Appending #{Enum.count(req.entries)} new entries" end)
      {:ok, index} = LogStore.append(state.log_store, req.entries)
      config = LogStore.get_config(state.log_store)
      IO.inspect(req.leader_commit, label: "Leaders commit index")
      state = commit_entries(req.leader_commit, state)
      state = %{state | leader: req.from, configuration: config}
      resp = %{resp | success: true, index: index}
      {:next_state, :follower, state, [{:reply, from, resp}]}
    else
      Logger.warn("#{state.me}: Log is out of date. Failing append")
      {:keep_state_and_data, [{:reply, from, resp}]}
    end
  end

  def follower(msg, event, data) do
    handle_event(msg, event, :follower, data)
  end


  defp set_term(term, %{current_term: current_term}=state) do
    cond do
      term > current_term -> %{state | current_term: term}
      term < current_term -> state
      true                -> state
    end
  end

  def commit_entries(leader_index, %{commit_index: commit_index}=state) when commit_index >= leader_index, do: state
  def commit_entries(leader_index, state) do
    last_index = min(leader_index, LogStore.last_index(state.log_store))

    # Starting at the last known index and working towards the new last index
    # apply each log to the state machine
    (state.commit_index..last_index)
    |> Enum.reduce(state, &commit_entry/2)
  end

  def commit_entry(index, state) do
    case LogStore.get_log(state.log_store, index) do
      {:ok, %{type: :config_change}=log} ->
        rpy = {:ok, state.configuration} # TODO - This is probably wrong
        respond_to_client_requests(state.client_reqs, log, rpy)
    end

    # TODO - actually apply things to the state machine
    %{state | commit_index: index}
  end

  def respond_to_client_requests(reqs, log, rpy) do
    reqs
    |> Enum.filter(fn req -> req.index == log.index end)
    |> Enum.each(fn req -> respond_to_client(req, rpy) end)
  end

  def respond_to_client(%{from: from}, rpy) do
    GenStateMachine.reply(from, rpy)
  end

  def consistent?(%{prev_log_index: 0, prev_log_term: 0}, _), do: true
  def consistent?(%{prev_log_index: index, prev_log_term: term}, state) do
    case LogStore.get_log(state.log_store, index) do
      {:ok, %{term: ^term}} ->
        true
      {:ok, %{term: _term}} ->
        false
      {:error, :not_found} ->
        false
    end
  end

  #
  # Candidate callbacks
  #

  defp become_candidate(%{followers: followers}=state) do
    state = State.increment_term(state)
    state = %{state | leader: :none}
    :ok = vote_for_myself(state)

    followers
    |> Enum.map(request_vote(state))
    |> RPC.broadcast

    reset_timeout(state)
  end

  defp become_leader(state) do
    case state.init_config do
      {id, from} ->
        Logger.debug("#{state.me}: Becoming leader with initial config")
        index = LogStore.last_index(state.log_store)
        next_index = initial_indexes(state, index+1)
        match_index = initial_indexes(state, 0)
        state = %{state | next_index: next_index, match_index: match_index}
        entry = Log.configuration(1, state.current_term, state.configuration)
        state = append(state, id, from, entry)
        send_append_entries(state)
        state = reset_timeout(heartbeat_timeout(), state)
        %{state | init_config: :complete}

      _ ->
        state
    end
  end

  defp initial_indexes(%{followers: followers}=state, index) do
    followers
    |> Enum.map(fn f -> {f, index} end)
    |> Enum.into(%{})
  end

  # if we can't get a quorum on our initial election we let the client know
  # that there was an error and retry until the nodes come up
  def candidate(:info, :timeout, %{term: 1, init_config: {_id, from}}=state) do
    Logger.warn("Cluster is unreachable for initial configuration")
    state = reset_timeout(state)
    # Send message back to client
    GenStateMachine.reply(from, {:error, :peers_not_responding})
    {:next_state, :candidate, state}
  end

  def candidate(:info, :timeout, state) do
    Logger.warn("Timeout reached. Starting Election")

    {:next_state, :candidate, become_candidate(state)}
  end

  def candidate({:call, from}, {:config_change, _change}, _state) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_leader}}]}
  end

  def candidate(:cast, %RequestVoteResp{}=resp, %{followers: followers}=state) do
    Logger.debug("Received vote")

    state = State.add_vote(state, resp)

    cond do
      resp.term > state.current_term ->
        Logger.debug("Newer term discovered, falling back to follower")
        {:next_state, :follower, %{state | current_term: resp.term}}
      State.majority?(state) ->
        Logger.info("Election won. Tally: #{state.votes}")

        # followers
        # |> Enum.map(heartbeat(state))
        # |> RPC.broadcast

        {:next_state, :leader, become_leader(state)}
      true ->
        Logger.debug(
          "Vote granted from #{resp.from} to #{state.me} in term #{state.current_term}. " <>
          "Tally: #{state.votes}"
        )
        {:next_state, :candidate, state}
    end
  end

  def candidate(msg, event, data) do
    # Logger.warn("Got a message as a candidate, #{inspect event}")
    handle_event(msg, event, :candidate, data)
  end

  # def handle_event({:call, from}, :current_state, state, data) do
  #   {:next_state, state, data, [{:reply, from, state}]}
  # end

  # def handle_event({:call, from}, {:get, key}, state, data) do
  #   {:ok, value} = Log.get(key)
  #   {:keep_state_and_data, [{:reply, from, value}]}
  # end

  # def handle_event({:call, from}, {:put, key, value}, state, data) do
  #   {:ok, value} = Log.put(key, value)
  #   {:keep_state_and_data, [{:reply, from, value}]}
  # end

  def handle_event({:call, from}, :status, current_state, state) do
    status = %{
      name: state.config.name,
      current_state: current_state,
      leader: state.leader,
      configuration: state.configuration,
    }
    {:keep_state_and_data, [{:reply, from, status}]}
  end

  # def handle_event(:cast, %AppendEntriesReq{}=req, current_state, state) do
  #   state = %{state | leader: req.leader_id}
  #   state = reset_timeout(state)
  #   {:next_state, :follower, state}
  # end

  def handle_event({:call, from}, %RequestVoteReq{}=req, current_state, state) do
    Logger.debug("Getting a request vote req")
    with {:ok, last_vote_term} <- LogStore.get(state.log_store, @last_vote_term),
         {:ok, last_vote_cand} <- LogStore.get(state.log_store, @last_vote_cand) do

      vote_granted =
        cond do
          req.term < state.current_term -> # Their term is behind ours
            false
          last_vote_term == req.term && # We've alredy voted in this term
          not is_nil(last_vote_cand) &&
          last_vote_cand != req.candidate_id ->
            false
          # up_to_date TODO: Check to ensure the logs are up to date
          true -> # Otherwise grant our vote
            true
        end

      to = req.candidate_id
        # state.configuration.servers
        # |> Enum.find(& &1.name == req.candidate_id)

      Logger.debug("Vote granted for #{to}? #{vote_granted}")


      case persist_vote(state.log_store, req.term, req.candidate_id) do
        :ok ->
          # TODO: Make all of these defaults or something so its cleaner
          resp = %RequestVoteResp{
            to: to,
            from: state.me,
            term: state.current_term,
            vote_granted: vote_granted,
          }
          {:keep_state_and_data, [{:reply, from, resp}]}
        {:error, error} ->
          Logger.error("Failed to persist vote: #{error}")
          {:keep_state_and_data, [{:reply, from, error}]}
      end
    else
      {:error, error} ->
        Logger.error("Error while casting vote: #{error}")

      {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  # def handle_event(:info, :timeout, :follower, state) do
  #   Logger.warn("Timeout reached. Starting Election")

  #   state = State.increment_term(state)
  #   :ok = vote_for_myself(state)

  #   state
  #   |> State.other_servers
  #   |> Enum.map(request_vote(state))
  #   |> RPC.broadcast

  #   start_next_timeout(state)

  #   {:next_state, :candidate, State.increment_term(state)}
  # end

  def handle_event(event_type, event, state, _data) do
    Logger.debug(fn ->
      "Unhandled event, #{inspect event_type}, #{inspect event}, #{inspect state}"
    end)

    {:keep_state_and_data, []}
  end

  defp election_timeout(%{config: config}) do
    Config.election_timeout(config)
  end

  defp heartbeat_timeout, do: 25

  defp reset_timeout(state) do
    reset_timeout(election_timeout(state), state)
  end

  defp reset_timeout(timeout, %{timer: timer, config: config}=state) do
    if timer do
      _ = Process.cancel_timer(timer)
    end

    timeout = Config.election_timeout(config)
    timer = Process.send_after(self(), :timeout, timeout)
    %{state | timer: timer}
  end

  defp vote_for_myself(state) do
    persist_vote(state.log_store, state.current_term, state.config.name)
  end

  defp persist_vote(log_store, term, candidate) do
    with :ok <- LogStore.set(log_store, @last_vote_term, term),
         :ok <- LogStore.set(log_store, @last_vote_cand, candidate) do
      :ok
    end
  end

  defp request_vote(state) do
    fn server ->
      %RPC.RequestVoteReq{
        to: server,
        from: state.me,
        term: state.current_term,
        candidate_id: state.me,
        last_log_index: state.last_index,
        last_log_term: %{},
      }
    end
  end

  defp heartbeat(state) do
    fn server ->
      %RPC.AppendEntriesReq{
        to: server,
        from: state.me,
        leader_id: state.config.name,
        prev_log_index: 0,
        prev_log_term: 0,
        leader_commit: 0,
        term: state.current_term,
        entries: [],
      }
    end
  end

  defp previous(_state, 1), do: {0, 0}
  defp previous(state, index) do
    IO.inspect(index, label: "Index")
    prev_index = index-1
    {:ok, log} = LogStore.get_log(state.log_store, prev_index)
    {prev_index, log.term}
  end

  defp send_entry(%{next_index: indexes, commit_index: commit_index}=state) do
    fn server ->
      index = indexes[server]
      {prev_index, prev_term} = previous(state, index)
      {:ok, log} = LogStore.get_log(state.log_store, index) # TODO - Get a slice of logs here.

      %RPC.AppendEntriesReq{
        to: server,
        from: state.me,
        leader_id: state.me,
        prev_log_index: prev_index,
        prev_log_term: prev_term,
        leader_commit: commit_index,
        term: state.current_term,
        entries: [log],
      }
    end
  end

  defp append(state, id, from, entry) do
    {:ok, index} = LogStore.append(state.log_store, [entry])
    req = %{id: id, from: from, index: index, term: state.current_term}
    %{state | client_reqs: [req | state.client_reqs]}
  end
end

