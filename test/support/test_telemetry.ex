defmodule Encryptor.Ecto.TestTelemetry do
  @moduledoc """
  Collecting one test's own `[:encryptor_ecto, :legacy_load]` events.

  `:telemetry.attach/4` is global. A handler an async case attaches runs in
  *every* process that emits the event, including the other async cases
  running beside it, so a per-test handler id - which is what keeps two cases
  from evicting each other - says nothing at all about whose emission the
  handler is looking at. A case that only checked the id would read a
  neighbour's event as its own, and the two tests that broke that way cost a
  red gate to diagnose.

  So the handler also refuses an event it did not cause. A telemetry handler
  runs in the emitting process, which makes comparing that process against
  the test that attached the handler an exact test of ownership - and one
  that needs nothing from the event's metadata, which ADR-0004 decision 5
  closes at the table and the column with no room for a test to identify
  itself in.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @event [:encryptor_ecto, :legacy_load]

  @doc """
  Forwards this test's own `legacy_load` events to its mailbox, for its
  duration.

  An `ExUnit` setup hook: `setup :capture_legacy_load`, with this module
  imported.
  """
  @spec capture_legacy_load(map()) :: :ok
  def capture_legacy_load(context) do
    id = {__MODULE__, context.test, make_ref()}
    owner = self()

    :ok = :telemetry.attach(id, @event, &__MODULE__.forward/4, owner)

    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  # A named function rather than a closure, because `:telemetry` logs an
  # advisory on every local-function handler and the suite's output is worth
  # more than the two lines it saves.
  @spec forward(:telemetry.event_name(), map(), map(), pid()) :: :ok
  def forward(event, measurements, metadata, owner) do
    if self() == owner do
      send(owner, {:telemetry, event, measurements, metadata})
    end

    :ok
  end
end
