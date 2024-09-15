defmodule MAVLink.LocalConnection do
  @moduledoc false
  # MAVLink.Router delegate for local connections, i.e
  # Elixir processes using the Router API to subscribe to
  # and send MAVLink messages.

  require Logger

  alias MAVLink.Frame
  alias MAVLink.{LocalConnection, SubscriptionCache}

  defstruct system: nil,
            component: nil,
            subscriptions: [],
            sequence_number: 0

  @type t :: %LocalConnection{
          system: 1..255,
          component: 1..255,
          subscriptions: [],
          sequence_number: 0..255
        }

  # Handle message from Router.pack_and_send()
  # We use handle_info instead of cast for symmetry
  # with the other connection types
  def handle_info(
        {:local, frame},
        receiving_connection = %LocalConnection{
          system: system,
          component: component,
          sequence_number: sequence_number
        },
        _dialect
      ) do
    # Fill in missing frame details source_system, source_component, sequence_number
    {
      :ok,
      :local,
      %{receiving_connection | sequence_number: rem(sequence_number + 1, 255)},
      %{
        frame
        | source_system: system,
          source_component: component,
          sequence_number: sequence_number
      }
      |> Frame.pack_frame()
    }
  end

  def connect(:local, system, component) do
    local_connection = %LocalConnection{system: system, component: component}

    Logger.debug("Restoring subscriptions from Subscription Cache")

    local_connection =
      SubscriptionCache.get_subscriptions()
      |> Enum.reduce(
        local_connection,
        fn {query, pid}, lc -> subscribe(query, pid, lc) end
      )

    send(
      # Local connection guaranteed, so this connect() called directly from Router process
      self(),
      {
        :add_connection,
        :local,
        local_connection
      }
    )
  end

  def forward(to_connection, frame = %Frame{message: nil}) do
    # If we couldn't unpack the message set the message_type to MAVLink.UnknownMessage
    forward(to_connection, %{frame | message: %{__struct__: MAVLink.UnknownMessage}})
  end

  def forward(
        %LocalConnection{
          subscriptions: subscriptions
        },
        frame = %Frame{
          source_system: source_system,
          source_component: source_component,
          target_system: target_system,
          target_component: target_component,
          target: target,
          message: message = %{__struct__: message_type}
        }
      ) do
    subscriptions
    |> Enum.each(fn {q, pid} ->
      if (q.message == nil or q.message == message_type) and
           (q.source_system == 0 or q.source_system == source_system) and
           (q.source_component == 0 or q.source_component == source_component) and
           (q.target_system == 0 or
              (target != :broadcast and target != :component and q.target_system == target_system)) and
           (q.target_component == 0 or
              (target != :broadcast and target != :system and
                 q.target_component == target_component)) do
        send(pid, if(q.as_frame, do: frame, else: message))
      end
    end)
  end

  # Subscription request from subscriber
  def subscribe(query, pid, local_connection) do
    Logger.debug("Subscribe #{inspect(pid)} to query #{inspect(query)}")
    # Monitor so that we can unsubscribe dead processes
    Process.monitor(pid)
    # Uniq prevents duplicate subscriptions
    %LocalConnection{
      local_connection
      | subscriptions:
          [{query, pid} | local_connection.subscriptions]
          |> Enum.uniq()
          |> SubscriptionCache.update_subscriptions()
    }
  end

  # Unsubscribe request from subscriber
  def unsubscribe(pid, local_connection) do
    Logger.debug("Unsubscribe #{inspect(pid)}")

    %LocalConnection{
      local_connection
      | subscriptions:
          local_connection.subscriptions
          |> Enum.filter(&(not match?({_, ^pid}, &1)))
          |> SubscriptionCache.update_subscriptions()
    }
  end

  # Automatically unsubscribe a dead subscriber process
  def subscriber_down(pid, local_connection) do
    Logger.debug("Subscriber #{inspect(pid)} exited")

    %LocalConnection{
      local_connection
      | subscriptions:
          local_connection.subscriptions
          |> Enum.filter(&(not match?({_, ^pid}, &1)))
          |> SubscriptionCache.update_subscriptions()
    }
  end
end
