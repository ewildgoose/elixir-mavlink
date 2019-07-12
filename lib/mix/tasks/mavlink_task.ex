defmodule Mix.Tasks.Mavlink do
  use Mix.Task

  
  import Mavlink.Parser
  import DateTime
  import Enum, only: [count: 1, join: 2, map: 2, filter: 2, reduce: 3, reverse: 1]
  import String, only: [trim: 1, replace: 3, split: 2, capitalize: 1]
  import Mavlink.Utils
  
  
  @shortdoc "Generate Mavlink Module from XML"
  @spec run([String.t]) :: :ok
  def run(["generate", input, output]) do
    case parse_mavlink_xml(input) do
      {:error, :enoent} ->
        IO.puts("Couldn't open input file '#{input}'.")
        
      %{version: version, dialect: dialect, enums: enums, messages: messages} ->
     
        enum_details = get_enum_details(enums)
        message_details = get_message_details(messages, enums)
        unit_details = get_unit_details(messages)
        
        File.write(output,
        """
        defmodule Mavlink do
          @moduledoc ~s(Mavlink #{version}.#{dialect} generated by Mavlink mix task from #{input} on #{utc_now()})
          
          
          @typedoc "An atom representing a Mavlink enumeration type"
          @type enum_type :: #{map(enums, & ":#{&1[:name]}") |> join(" | ")}
          
          
          @typedoc "An atom representing a Mavlink enumeration type value"
          @type enum_value :: #{map(enums, & "#{&1[:name]}") |> join(" | ")}
          
          
          #{enum_details |> map(& &1[:type]) |> join("\n\n  ")}
          
          
          @typedoc "A parameter description"
          @type param_description :: {non_neg_integer, String.t}
          
          
          @typedoc "A list of parameter descriptions"
          @type param_description_list :: [ param_description ]
          
          
          @typedoc "Type used for field in encoded message"
          @type field_type :: int8 | int16 | int32 | int64 | uint8 | uint16 | uint32 | uint64 | char | float | double
          
          
          @typedoc "8-bit signed integer"
          @type int8 :: -128..127
          
          
          @typedoc "16-bit signed integer"
          @type int16 :: -32_768..32_767
          
          
          @typedoc "32-bit signed integer"
          @type int32 :: -2_147_483_647..2_147_483_647
          
          
          @typedoc "64-bit signed integer"
          @type int64 :: integer
          
          
          @typedoc "8-bit unsigned integer"
          @type uint8 :: 0..255
          @type uint8_mavlink_version :: uint8
          
          
          @typedoc "16-bit unsigned integer"
          @type uint16 :: 0..65_535
          
          
          @typedoc "32-bit unsigned integer"
          @type uint32 :: 0..4_294_967_295
          
          
          @typedoc "64-bit unsigned integer"
          @type uint64 :: pos_integer
          
          @typedoc "64-bit signed float"
          @type double :: Float64
          
          
          @typedoc "0 -> not an array 1..255 -> an array"
          @type field_ordinality :: 0..255
          
          
          @typedoc "Measurement unit of field value"
          @type field_unit :: #{unit_details |> join(~s( | )) |> trim}
          
          
          @typedoc "A Mavlink message id"
          @type message_id :: pos_integer
          
          
          @doc "Mavlink version"
          @spec mavlink_version() :: integer
          def mavlink_version(), do: #{version}
          
          
          @doc "Mavlink dialect"
          @spec mavlink_dialect() :: integer
          def mavlink_dialect(), do: #{dialect}
          
          
          @doc "Return a String description of a Mavlink enumeration"
          @spec describe(enum_type | enum_value) :: String.t
          #{enum_details |> map(& &1[:describe]) |> join("\n  ") |> trim}
          
          
          @doc "Return keyword list of mav_cmd parameters"
          @spec describe_params(mav_cmd) :: param_description_list
          #{enum_details |> map(& &1[:describe_params]) |> join("\n  ") |> trim}
          
          
          @doc "Return encoded integer value used in a Mavlink message for an enumeration value"
          @spec encode(enum_value) :: integer
          #{enum_details |> map(& &1[:encode]) |> join("\n  ") |> trim}
          
          
          @doc "Return the atom representation of a Mavlink enumeration value from the enumeration type and encoded integer"
          @spec decode(enum_type, integer) :: enum_value
          #{enum_details |> map(& &1[:decode]) |> join("\n  ") |> trim}
          
          defprotocol Send do
            def send(message)
          end
          
          defimpl Send, for: [Atom, BitString, Float, Function, Integer, List, Map, PID, Port, Reference, Tuple] do
            def send(not_a_message), do: {:error, "send(): \#{inspect(not_a_message)} is not a Mavlink message"}
          end
          
        end
        
        #{message_details |> join("\n\n") |> trim}
        """
        )
      
        IO.puts("Generated output file '#{output}'.")
        :ok
    
    end
    
  end
  
  
  @type enum_detail :: %{type: String.t, describe: String.t, describe_params: String.t, encode: String.t, decode: String.t}
  @spec get_enum_details([%{name: String.t, description: String.t, entries: [%{}]}]) :: [ enum_detail ]
  defp get_enum_details(enums) do
    for enum <- enums do
      %{
        name: name,
        description: description,
        entries: entries
      } = enum
      
      entry_details = get_entry_details(name, entries)
      
      %{
        type: ~s/@typedoc "#{description}"\n  / <>
          ~s/@type #{name} :: / <>
          (map(entry_details, & ":#{&1[:name]}") |> join(" | ")),
          
        describe: ~s/def describe(:#{name}), do: "#{escape(description)}"\n  / <>
          (map(entry_details, & &1[:describe])
          |> join("\n  ")),
          
        describe_params: filter(entry_details, & &1 != nil)
          |> map(& &1[:describe_params])
          |> join("\n  "),
          
        encode: map(entry_details, & &1[:encode])
          |> join("\n  "),
        
        decode: map(entry_details, & &1[:decode])
          |> join("\n  ")
      }
    end
  end
  
  
  @type entry_detail :: %{name: String.t, describe: String.t, describe_params: String.t, encode: String.t, decode: String.t}
  @spec get_entry_details(binary(), [%{name: String.t, description: String.t, value: integer | nil, params: [%{}]}]) :: [ entry_detail ]
  defp get_entry_details(enum_name, entries) do
    {details, _} = reduce(
      entries,
      {[], 0},
      fn entry, {details, next_value} ->
        %{
          name: entry_name,
          description: entry_description,
          value: entry_value,
          params: entry_params
        } = entry
        
        # Use provided value or continue monotonically from last value: in common.xml MAV_STATE uses this
        {entry_value_string, next_value} = case entry_value do
          nil ->
            {Integer.to_string(next_value), next_value + 1}
          _ ->
            {Integer.to_string(entry_value), entry_value + 1}
        end
        
        {
          [
            %{
              name: entry_name,
              describe: ~s/def describe(:#{entry_name}), do: "#{escape(entry_description)}"/,
              describe_params: get_param_details(entry_name, entry_params),
              encode: ~s/def encode(:#{entry_name}), do: #{entry_value_string}/,
              decode: ~s/def decode(:#{enum_name}, #{entry_value_string}), do: :#{entry_name}/
            }
            | details
          ],
          next_value
        }

      end
    )
    reverse(details)
  end
  
  
  @spec get_param_details(String.t, [%{index: non_neg_integer, description: String.t}]) :: String.t
  defp get_param_details(entry_name, entry_params) do
    cond do
      count(entry_params) == 0 ->
        nil
      true ->
        ~s/def describe_params(:#{entry_name}), do: [/ <>
        (map(entry_params, & ~s/{#{&1[:index]}, "#{&1[:description]}"}/) |> join(", ")) <>
        ~s/]/
    end
  end
  
  
  @spec get_message_details([%{}], [enum_detail]) :: [ String.t ]
  defp get_message_details(messages, enums) do
    for message <- messages do
      module_name = message.name |> module_case
      field_names = message.fields |> map(& ":" <> Atom.to_string(&1.name)) |> join(", ")
      field_types = message.fields |> map(& Atom.to_string(&1.name) <> ": " <> field_type(&1.type, &1.ordinality, &1.enum)) |> join(", ")
      wire_order = message.fields |> wire_order
      """
      defmodule Mavlink.#{module_name} do
        # wire order #{wire_order |> map(& "#{Atom.to_string(&1.name)}::#{&1.type}") |> join(", ")}
        @enforce_keys [#{field_names}]
        defstruct [#{field_names}]
        @typedoc "#{escape(message.description)}"
        @type t :: %Mavlink.#{module_name}{#{field_types}}
        defimpl Mavlink.Send do
          def send(_msg) do
            IO.puts("Sending a #{module_name} message")
          end
        end
      end
      """
    end
  end
  
  
  @spec get_unit_details([%{}]) :: [ String.t ]
  defp get_unit_details(messages) do
    reduce(
      messages,
      MapSet.new(),
      fn message, units ->
        reduce(
          message.fields,
          units,
          fn %{units: next_unit}, units ->
            cond do
              next_unit == nil ->
                units
              Regex.match?(~r/^[a-zA-Z0-9@_]+$/, Atom.to_string(next_unit)) ->
                MapSet.put(units, ~s(:#{next_unit}))
              true ->
                MapSet.put(units, ~s(:"#{next_unit}"))
            end
            
          end
        )
      end
    ) |> MapSet.to_list |> Enum.sort
  end
  
  
  defp module_case(name) do
    name
    |> Atom.to_string
    |> split("_")
    |> map(&capitalize/1)
    |> join("")
  end
  
  
  # Have to deal with some overlap between MAVLink and Elixir types
  defp field_type(type, ordinality, enum) when ordinality == 1, do: field_type(type, enum)
  defp field_type(type, ordinality, enum) when ordinality > 1, do: "[ #{field_type(type, enum)} ]"
  defp field_type(_, enum) when enum != nil, do: "Mavlink.#{Atom.to_string(enum)}"
  defp field_type(:char, _), do: "char"
  defp field_type(:float, _), do: "Float32"
  defp field_type(:uint8_t_mavlink_version, _), do: "Mavlink.uint8_mavlink_version" # If they think it's important to distinguish...
  defp field_type(type, _), do: "Mavlink.#{Atom.to_string(type)}"
  
  
  
  @spec escape(binary()) :: binary()
  defp escape(s) do
    replace(s, ~s("), ~s(\\"))
  end
  
  
end
