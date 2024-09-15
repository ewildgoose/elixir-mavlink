defmodule MAVLink.Application do
  @moduledoc false

  use Application

  def start(_, _) do
    children = [
      MAVLink.SubscriptionCache,
      MAVLink.Supervisor
    ]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
