defmodule MAVLink.SubscriptionCache do
  use Agent
  require Logger

  def start_link(_) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  def get_subscriptions() do
    Agent.get(__MODULE__, fn subs -> subs end)
  end

  def update_subscriptions(subscriptions) do
    Logger.debug("Update subscription cache: #{inspect(subscriptions)}")
    Agent.update(__MODULE__, fn _ -> subscriptions end)
    subscriptions
  end
end
