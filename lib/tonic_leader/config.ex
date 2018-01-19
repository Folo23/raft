defmodule TonicLeader.Config do
  @enforce_keys [:name]
  defstruct [
    name: :none,
    min_election_timeout: 150,
    max_election_timeout: 300,
    heartbeat_timeout: 200,
    data_dir: "",
  ]

  def new(opts) do
    valid_opts =
      default_opts()
      |> Keyword.merge(opts)
      |> validate!

    struct(__MODULE__, valid_opts)
  end

  def db_path(config), do: config |> data_dir |> Path.join("#{config.name}.tonic")

  def data_dir(%{data_dir: ""}), do: :tonic_leader
                                 |> Application.app_dir()
                                 # |> Path.join("data")

  def data_dir(%{data_dir: data_dir}), do: data_dir

  @doc """
  Generates a random timeout value between the min_election_timeout and
  max_election_timeout.
  """
  @spec election_timeout(Config.t) :: pos_integer()

  def election_timeout(%{min_election_timeout: min, max_election_timeout: max}) do
    case min < max do
      true -> :rand.uniform(max-min)+min
      _    -> throw :min_equals_max
    end
  end

  defp validate!(opts) do
    min = Keyword.get(opts, :min_election_timeout)
    max = Keyword.get(opts, :max_election_timeout)

    if min < max do
      opts
    else
      throw :min_equals_max
    end
  end

  defp default_opts(), do: [
      members: [],
      min_election_timeout: 150,
      max_election_timeout: 300,
      heartbeat_timeout: 200,
    ]
end
