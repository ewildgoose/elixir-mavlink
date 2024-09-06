defmodule MAVLink.Router do
  @moduledoc """
  Connect to serial, udp and tcp ports and listen for, validate and
  forward MAVLink messages towards their destinations on other connections
  and/or Elixir processes subscribing to messages.

  The rules for MAVLink packet forwarding are described here:

    https://mavlink.io/en/guide/routing.html

  and here:

    http://ardupilot.org/dev/docs/mavlink-routing-in-ardupilot.html
  """

  use GenServer
  require Logger

  import MAVLink.Utils, only: [parse_ip_address: 1, parse_positive_integer: 1]

  alias MAVLink.Types
  alias MAVLink.Frame
  alias MAVLink.Message
  alias MAVLink.Router
  alias MAVLink.LocalConnection
  alias MAVLink.SerialConnection
  alias MAVLink.TCPOutConnection
  alias MAVLink.UDPInConnection
  alias MAVLink.UDPOutConnection
  alias Circuits.UART

  @typedoc """
  Represents the state of the MAVLink.Router. Initial values should be set in config.exs.

  ## Fields
  - dialect:            The MAVLink dialect module generated by mix mavlink from a MAVLink definition file
  - connection_strings: Configuration strings describing the network and serial connections MAVLink messages
                        are to be received and sent over. Allowed formats are:

                        ```udpin:<local ip>:<local port>
                        udpout:<remote ip>:<remote port>
                        tcpout:<remote ip>:<remote port>
                        serial:<device>:<baud rate>```

                        Note there is no tcpin connection - tcp is rarely used for MAVLink, the exception
                        being SITL testing which requires a tcpout connection.

  - connections:        A map containing the state of the connections described by connection_strings along
                        with the local connection, which is automatically created and responsible for allowing
                        Elixir processes to receive and send MAVLink messages. The map is keyed by the port,
                        device or :local to allow the corresponding connection state to be easily retrieved
                        when we receive a message. See MAVLink.*Connection for map values. Note LocalConnection
                        contains the system/component id, subscriber list and next sequence number.
  - routes:             A map from a {system id, component id} tuple to the connection key a message from that
                        system/component was last received on. Used to forward messages to that system/component.
  """
  defstruct [
    # Generated dialect module
    dialect: nil,
    # Connection descriptions from user
    connection_strings: [],
    # %{socket|port|local: MAVLink.*_Connection}
    connections: %{},
    # Connection and MAVLink version tuple keyed by MAVLink addresses
    routes: %{}
  ]

  # Can't used qualified type as map key
  @type mavlink_address :: Types.mavlink_address()
  @type mavlink_connection :: Types.connection()
  @type t :: %Router{
          dialect: module | nil,
          connection_strings: [String.t()],
          connections: %{},
          routes: %{mavlink_address: {mavlink_connection, Types.version()}}
        }

  ##############
  # Router API #
  ##############

  @doc """
  Start the MAVLink Router service. You should not call this directly, use the MAVLink application
  to start this under a supervision tree with the services it expects to use.

  ## Parameters
  - dialect:            Name of the module generated by mix mavlink task to represent the enumerations
                        and messages of a particular MAVLink dialect
  - system:             The System id of this system  1..255, typically low for vehicles and high for
                        ground stations
  - component:          The component id of this system 1..255, typically 1 for the autopilot
  - connection_strings: A list of strings in the following formats:

                        udpin:<local ip>:<local port>
                        udpout:<remote ip>:<remote port>
                        tcpout:<remote ip>:<remote port>
                        serial:<device>:<baud rate>

  - opts:               Standard GenServer options
  """
  @spec start_link(
          %{system: 1..255, component: 1..255, dialect: module, connection_strings: [String.t()]},
          [{atom, any}]
        ) :: {:ok, pid}
  def start_link(args, opts \\ []) do
    GenServer.start_link(
      __MODULE__,
      args,
      [{:name, __MODULE__} | opts]
    )
  end

  @doc """
  Subscribes the calling process to MAVLink messages from the installed dialect matching the query.

  ## Parameters

  - query:  Keyword list of zero or more of the following query keywords:

    message:          message_module | :unknown (use latter with as_frame)
    source_system:    integer 0..255
    source_component: integer 0..255
    target_system:    integer 0..255
    target_component: integer 0..255
    as_frame:         true|false (default false, shows entire message frame with sender/target details)

  ## Example

  ```
    MAVLink.Router.subscribe message: MAVLink.Message.Heartbeat, source_system: 1
  ```
  """
  @type subscribe_query_id_key ::
          :source_system | :source_component | :target_system | :target_component
  @spec subscribe([
          {:message, Message.t()} | {subscribe_query_id_key, 0..255} | {:as_frame, boolean}
        ]) :: :ok
  def subscribe(query \\ []) do
    with message <- Keyword.get(query, :message),
         true <- message == nil or Code.ensure_loaded?(message) do
      GenServer.cast(
        __MODULE__,
        {
          :subscribe,
          [
            message: nil,
            source_system: 0,
            source_component: 0,
            target_system: 0,
            target_component: 0,
            as_frame: false
          ]
          |> Keyword.merge(query)
          |> Enum.into(%{}),
          self()
        }
      )
    else
      false ->
        {:error, :invalid_message}
    end
  end

  @doc """
  Un-subscribes calling process from all existing subscriptions

  ## Example

  ```
    MAVLink.Router.unsubscribe
  ```
  """
  @spec unsubscribe() :: :ok
  def unsubscribe(), do: GenServer.cast(__MODULE__, {:unsubscribe, self()})

  @doc """
  Send a MAVLink message to one or more recipients using available
  connections. For now if destination is unreachable it will log
  a warning

  ## Parameters

  - message: A MAVLink message structure from the installed dialect
  - version: Force sending using a specific MAVLink protocol (default 2)

  ## Example

  ```
    MAVLink.Router.pack_and_send(
      %APM.RcChannelsOverride{
        target_system: 1,
        target_component: 1,
        chan1_raw: 1500,
        chan2_raw: 1500,
        chan3_raw: 1500,
        chan4_raw: 1500,
        chan5_raw: 1500,
        chan6_raw: 1500,
        chan7_raw: 1500,
        chan8_raw: 1500,
        chan9_raw: 0,
        chan10_raw: 0,
        chan11_raw: 0,
        chan12_raw: 0,
        chan13_raw: 0,
        chan14_raw: 0,
        chan15_raw: 0,
        chan16_raw: 0,
        chan17_raw: 0,
        chan18_raw: 0
      }
    )
  ```
  """
  def pack_and_send(message, version \\ 2) do
    # We can only pack payload at this point because we need router state to get source
    # system/component and sequence number for frame
    try do
      {:ok, message_id, {:ok, crc_extra, _, target}, payload} = Message.pack(message, version)

      {target_system, target_component} =
        if target != :broadcast do
          {message.target_system, Map.get(message, :target_component, 0)}
        else
          {0, 0}
        end

      # Although Router is a GenServer we still use send for symmetry because this arrives as
      # a vanilla message, just like messages from a udp/tcp/serial port, and is dealt with in
      # a similar way using handle_info()
      send(
        __MODULE__,
        {
          :local,
          %Frame{
            version: version,
            message_id: message_id,
            target_system: target_system,
            target_component: target_component,
            target: target,
            message: message,
            payload: payload,
            crc_extra: crc_extra
          }
        }
      )

      :ok
    rescue
      # Need to catch Protocol.UndefinedError - happens with SimState (Common) and Simstate (APM)
      # messages because non-case-sensitive filesystems (including OSX thanks @noobz) can't tell
      # the difference between generated module beam files. Work around is comment out one of the
      # message definitions and regenerate the dialect module.
      Protocol.UndefinedError ->
        {:error, :protocol_undefined}
    end
  end

  #######################
  # GenServer Callbacks #
  #######################

  @impl true
  # No dialect, no play.
  def init(%{dialect: nil}) do
    {:error, :no_mavlink_dialect_set}
  end

  # Start connections (they will send :add_connection messages
  # to us if successful) and initialise Router state
  def init(args) do
    LocalConnection.connect(:local, args.system, args.component)
    _ = Enum.map(args.connection_strings, &connect/1)
    {:ok, %Router{dialect: args.dialect, connection_strings: args.connection_strings}}
  end

  @impl true
  # Call to subscribe() API
  def handle_cast({:subscribe, query, pid}, state) do
    {:noreply,
     update_in(
       state,
       [Access.key!(:connections), :local],
       &LocalConnection.subscribe(query, pid, &1)
     )}
  end

  # Call to unsubscribe() API
  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply,
     update_in(state, [Access.key!(:connections), :local], &LocalConnection.unsubscribe(pid, &1))}
  end

  @impl true
  # Receive data on UDP connection
  def handle_info(
        message = {:udp, socket, address, port, _},
        state = %Router{connections: connections, dialect: dialect}
      ) do
    {
      :noreply,
      case connections[{socket, address, port}] do
        connection = %UDPInConnection{} ->
          UDPInConnection.handle_info(message, connection, dialect)

        connection = %UDPOutConnection{} ->
          UDPOutConnection.handle_info(message, connection, dialect)

        nil ->
          # New previously unseen UDPIn client
          UDPInConnection.handle_info(message, nil, dialect)
      end
      |> update_route_info(state)
      |> route
    }
  end

  # Receive data on TCP connection
  def handle_info(message = {:tcp, socket, _}, state) do
    {
      :noreply,
      TCPOutConnection.handle_info(message, state.connections[socket], state.dialect)
      |> update_route_info(state)
      |> route
    }
  end

  # Unlike UDP, TCP connections can close
  def handle_info({:tcp_closed, socket}, state) do
    %TCPOutConnection{address: address, port: port} = state.connections[socket]
    spawn(TCPOutConnection, :connect, [["tcpout", address, port], self()])
    {:noreply, remove_connection(socket, state)}
  end

  # Received data on serial connection
  def handle_info(message = {:circuits_uart, port, raw}, state) when is_binary(raw) do
    {
      :noreply,
      SerialConnection.handle_info(message, state.connections[port], state.dialect)
      |> update_route_info(state)
      |> route
    }
  end

  # Received error on serial connection
  def handle_info({:circuits_uart, port, {:error, _reason}}, state) do
    %SerialConnection{baud: baud, uart: uart} = state.connections[port]

    spawn(SerialConnection, :connect, [
      ["serial", port, baud, :poolboy.checkout(MAVLink.UARTPool)],
      self()
    ])

    :ok = UART.close(uart)
    # After checkout to make sure we get a fresh UART, this one might be reused later
    :poolboy.checkin(MAVLink.UARTPool, uart)
    {:noreply, remove_connection(port, state)}
  end

  # A local subscribing Elixir process has crashed, remove them from our subscriber list
  def handle_info({:DOWN, _, :process, pid, _}, state),
    do:
      {:noreply,
       update_in(
         state,
         [Access.key!(:connections), :local],
         &LocalConnection.subscriber_down(pid, &1)
       )}

  # A call to pack_and_send() from a local Elixir process, sent as a vanilla message for symmetry with other connection types
  def handle_info({:local, frame}, state) do
    {
      :noreply,
      LocalConnection.handle_info({:local, frame}, state.connections.local, state.dialect)
      |> update_route_info(state)
      |> route
    }
  end

  # A spawned *Connection.connect() call has successfully got a
  # connection, and wants to add it to our connection list.
  def handle_info(
        {:add_connection, connection_key, connection},
        state = %Router{connections: connections}
      ) do
    {
      :noreply,
      %{state | connections: Map.put(connections, connection_key, connection)}
    }
  end

  # Ignore weird messages
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ####################
  # Helper Functions #
  ####################

  # Handle user configured connections by spawning a process to try to connect. If successful they will send
  # us an :add_connection message with the details. The local connection gets added automatically.
  defp connect(connection_string) when is_binary(connection_string),
    do: connect(String.split(connection_string, [":", ","]))

  defp connect(tokens = ["udpin" | _]),
    do: spawn(UDPInConnection, :connect, [validate_address_and_port(tokens), self()])

  defp connect(tokens = ["udpout" | _]),
    do: spawn(UDPOutConnection, :connect, [validate_address_and_port(tokens), self()])

  defp connect(tokens = ["tcpout" | _]),
    do: spawn(TCPOutConnection, :connect, [validate_address_and_port(tokens), self()])

  defp connect(tokens = ["serial" | _]),
    do: spawn(SerialConnection, :connect, [validate_port_and_baud(tokens), self()])

  defp connect([invalid_protocol | _]),
    do: raise(ArgumentError, message: "invalid protocol #{invalid_protocol}")

  # Parse network connection strings
  defp validate_address_and_port([protocol, address, port]) do
    case {parse_ip_address(address), parse_positive_integer(port)} do
      {{:error, :invalid_ip_address}, _} ->
        raise ArgumentError, message: "invalid ip address #{address}"

      {_, :error} ->
        raise ArgumentError, message: "invalid port #{port}"

      {parsed_address, parsed_port} ->
        [protocol, parsed_address, parsed_port]
    end
  end

  # Parse serial port connection string
  defp validate_port_and_baud(["serial", port, baud]) do
    case {is_binary(port), parse_positive_integer(baud)} do
      {false, _} ->
        raise ArgumentError, message: "Invalid port #{port}"

      {_, :error} ->
        raise ArgumentError, message: "invalid baud rate #{baud}"

      {true, parsed_baud} ->
        # Have to checkout from uart pool in main process because
        # poolboy monitors the process that calls checkout, and
        # returns the UART to the pool when the caller dies. This
        # happens immediately to our spawned connect() calls so we
        # can't do this there, which would otherwise be a logical
        # place to do it.
        ["serial", port, parsed_baud, :poolboy.checkout(MAVLink.UARTPool)]
    end
  end

  # A handle_info() received an error and wants us to forget the borked connection
  defp remove_connection(connection_key, state = %Router{connections: connections}) do
    %{state | connections: Map.delete(connections, connection_key)}
  end

  # Map system/component ids to connections on which they have been seen for targeted messages
  # Keep a list of all connections we have received messages from for broadcast messages
  defp update_route_info(
         {:ok, source_connection_key, source_connection,
          frame = %Frame{
            source_system: source_system,
            source_component: source_component
          }},
         state = %Router{routes: routes, connections: connections}
       ) do
    {
      :ok,
      source_connection_key,
      frame,
      %{
        state
        | # Don't add system/components from local connection to routes because local
        # automatically matches everything in matching_system_components() and we
        # don't want to receive messages twice
        routes:
          case source_connection_key do
            :local ->
              routes

            _ ->
              Map.put(
                routes,
                {source_system, source_component},
                source_connection_key
              )
          end,
        connections:
          Map.put(
            connections,
            source_connection_key,
            source_connection
          )
      }
    }
  end

  # Connection state still needs to be updated if there is an error
  defp update_route_info(
         {:error, reason, connection_key, connection},
         state = %Router{connections: connections}
       ) do
    {
      :error,
      reason,
      %{
        state
        | connections:
          Map.put(
            connections,
            connection_key,
            connection
          )
      }
    }
  end

  # Broadcast un-targeted messages to all connections except the
  # source we received the message from, unless it was local
  defp route(
         {:ok, source_connection_key, frame = %Frame{target: :broadcast},
          state = %Router{connections: connections}}
       ) do
    for {connection_key, connection} <- connections do
      if match?(:local, connection_key) or !match?(^connection_key, source_connection_key) do
        forward(connection, frame)
      end
    end

    state
  end

  # Only send targeted messages to observed system/components and local
  # Log warning if a message sent locally cannot reach its remote destination
  defp route(
         {:ok, _,
          frame = %Frame{
            source_system: source_system,
            source_component: source_component,
            target_system: target_system,
            target_component: target_component,
            message: %{__struct__: message_type}
          }, state = %Router{connections: connections}}
       ) do
    recipients = matching_system_components(target_system, target_component, state)

    if match?(
         {^recipients, ^source_system, ^source_component},
         {[:local], connections.local.system, connections.local.component}
       ) do
      :ok =
        Logger.debug(
          "Could not send message #{Atom.to_string(message_type)} to #{target_system}/#{target_component}: destination unreachable"
        )
    end

    for connection_key <- recipients do
      forward(connections[connection_key], frame)
    end

    state
  end

  # Swallow any errors from the handle_info |> update_connection_info pipeline
  defp route({:error, _reason, state = %Router{}}), do: state

  # Known system/components matching target with 0 wildcard
  # Always include local connection because we get to snoop
  # on everybody's messages
  defp matching_system_components(q_system, q_component, %Router{routes: routes}) do
    [
      :local
      | routes
        |> Enum.filter(fn {{sid, cid}, _} ->
          (q_system == 0 or q_system == sid) and
            (q_component == 0 or q_component == cid)
        end)
        |> Enum.map(fn {_, ck} -> ck end)
    ]
  end

  # Delegate sending a message to connection-type specific code
  defp forward(connection = %UDPInConnection{}, frame),
    do: UDPInConnection.forward(connection, frame)

  defp forward(connection = %UDPOutConnection{}, frame),
    do: UDPOutConnection.forward(connection, frame)

  defp forward(connection = %TCPOutConnection{}, frame),
    do: TCPOutConnection.forward(connection, frame)

  defp forward(connection = %SerialConnection{}, frame),
    do: SerialConnection.forward(connection, frame)

  defp forward(connection = %LocalConnection{}, frame),
    do: LocalConnection.forward(connection, frame)
end
