defmodule YellowDog.Tasks.Job do
  @moduledoc """
  Persisted background task execution record.

  Job records are stored through `YellowDog.Store` so production persistence
  follows YellowDog's configured Concord-backed database path.
  """

  @type state :: String.t()

  @type t :: %__MODULE__{
          id: String.t(),
          task_key: atom() | String.t(),
          worker: module(),
          queue: String.t(),
          args: map(),
          state: state(),
          attempt: non_neg_integer(),
          max_attempts: pos_integer(),
          inserted_at: DateTime.t(),
          scheduled_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          discarded_at: DateTime.t() | nil,
          errors: [map()]
        }

  defstruct id: nil,
            task_key: nil,
            worker: nil,
            queue: "data_sync",
            args: %{},
            state: "available",
            attempt: 0,
            max_attempts: 3,
            inserted_at: nil,
            scheduled_at: nil,
            started_at: nil,
            completed_at: nil,
            discarded_at: nil,
            errors: []
end
