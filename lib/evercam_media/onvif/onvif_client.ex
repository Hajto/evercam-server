defmodule EvercamMedia.ONVIFClient do
  require Logger
  require Record
  Record.defrecord :xmlElement, Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  Record.defrecord :xmlText, Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")
  Record.defrecord :xmlAttribute, Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")

  def request(%{"url" => base_url, "auth" => auth}, service, operation, parameters \\ "") do
    url = "#{base_url}/onvif/#{service}"
    namespace =  shorten_service(service)

    [username, password] = auth |> String.split(":")
    onvif_request = gen_onvif_request(namespace, operation, username, password, parameters)
    case HTTPoison.post(url, onvif_request, ["Content-Type": "application/soap+xml", "SOAPAction": "http://www.w3.org/2003/05/soap-envelope"]) do
      {:ok, response} ->
        {xml, _rest} = response.body |> to_char_list |> :xmerl_scan.string
        soap_ns = case elem(xml, 3) do
                {ns, _} -> ns
                  _ -> "env"
                end
        if response.status_code == 200 do
          case "/#{soap_ns}:Envelope/#{soap_ns}:Body/#{namespace}:#{operation}Response" |> to_char_list |> :xmerl_xpath.string(xml) do
            [] -> {:error, 405, "/#{soap_ns}:Envelope/#{soap_ns}:Body" |> to_char_list |> :xmerl_xpath.string(xml) |> parse_elements}
            xpath_string -> {:ok, parse_elements xpath_string}
          end
        else
          Logger.error "Error invoking #{operation}. URL: #{url} auth: #{auth}. Request: #{inspect onvif_request}. Response #{inspect response}."
          case "/html" |> to_char_list |> :xmerl_xpath.string(xml) do
            [] ->  {:error, response.status_code, "/#{soap_ns}:Envelope/#{soap_ns}:Body" |> to_char_list |> :xmerl_xpath.string(xml) |> parse_elements}
            contents -> {:error, response.status_code, contents |> parse_elements}
          end
        end
      {:error, %HTTPoison.Error{reason: reason}} -> {:error, 500, reason}
    end
  end

  defp gen_onvif_request(namespace, operation, username, password, parameters) do
    wsdl_url =
      case namespace do
        "tptz" -> "http://www.onvif.org/ver20/ptz/wsdl"
        "tds" -> "http://www.onvif.org/ver20/device/wsdl"
        "trt" -> "http://www.onvif.org/ver10/media/wsdl"
        "tls" -> "http://www.onvif.org/ver10/display/wsdl"
        "tev" -> "http://www.onvif.org/ver10/events/wsdl"
        "timg" -> "http://www.onvif.org/ver20/imaging/wsdl"
        "tan" -> "http://www.onvif.org/ver20/analytics/wsdl"
        "tad" -> "http://www.onvif.org/ver10/analyticsdevice/wsdl"
        "tst" -> "http://www.onvif.org/ver10/storage/wsdl"
        "dn" -> "http://www.onvif.org/ver10/network/wsdl"
        "tmd" -> "http://www.onvif.org/ver10/deviceIO/wsdl"
        "trc" -> "http://www.onvif.org/ver10/recording/wsdl"
        "trec" -> "http://www.onvif.org/ver10/recording/wsdl"
        "tse" -> "http://www.onvif.org/ver10/search/wsdl"
        "trsrch" -> "http://www.onvif.org/ver10/search/wsdl"
        "trp" -> "http://www.onvif.org/ver10/replay/wsdl"
        "treplay" -> "http://www.onvif.org/ver10/replay/wsdl"
        "trv" -> "http://www.onvif.org/ver10/receiver/wsdl"
        "trcv" -> "http://www.onvif.org/ver10/receiver/wsdl"
       end

    {wsse_username, wsse_password, wsse_nonce, wsse_created} = get_wsse_header_data(username,password)

    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
    <SOAP-ENV:Envelope xmlns:SOAP-ENV=\"http://www.w3.org/2003/05/soap-envelope\"
    xmlns:wsse=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd\"
    xmlns:wsu=\"http://docs.oasis-open.org/wss/2004/01/oasis=200401-wss-wssecurity-utility-1.0.xsd\">
    <SOAP-ENV:Header><wsse:Security><wsse:UsernameToken>
    <wsse:Username>#{wsse_username}</wsse:Username>
    <wsse:Password Type=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest\">#{wsse_password}</wsse:Password>
    <wsse:Nonce>#{wsse_nonce}</wsse:Nonce>
    <wsu:Created>#{wsse_created}</wsu:Created></wsse:UsernameToken>
    </wsse:Security></SOAP-ENV:Header><SOAP-ENV:Body>
    <#{namespace}:#{operation} xmlns:#{namespace}=\"#{wsdl_url}\">#{parameters}</#{namespace}:#{operation}>
    </SOAP-ENV:Body></SOAP-ENV:Envelope>"
  end


  #### WSSE

  @doc """
  Provides short for given service
  """

  defp shorten_service(service)
  defp shorten_service("PTZ"), do: "tptz"
  defp shorten_service("ptz_service"), do: "tptz"
  defp shorten_service("device_service"), do:  "tds"
  defp shorten_service("Media"), do: "trt"
  defp shorten_service("media_service"), do:  "trt"
  defp shorten_service("Display"), do: "tls"
  defp shorten_service("Events"), do: "tev"
  defp shorten_service("event_service"), do:  "tev"
  defp shorten_service("Analytics"), do:  "tan"
  defp shorten_service("AnalyticsDevice"), do:  "tad"
  defp shorten_service("DeviceIO"), do:  "tmd"
  defp shorten_service("Imaging"), do: "timg"
  defp shorten_service("imaging_service"), do:  "timg"
  defp shorten_service("Search"), do: "tse"
  defp shorten_service("search_service"), do:  "trsrch"
  defp shorten_service("Replay"), do:  "trp"
  defp shorten_service("replay_service"), do:  "treplay"
  defp shorten_service("Recording"), do:  "trc"
  defp shorten_service("recording_service"), do:  "trec"
  defp shorten_service("Storage"), do:  "tst"
  defp shorten_service("Receiver"), do: "trv"
  defp shorten_service("receiver_service"), do:  "trcv"
  defp shorten_service("Network"), do:  "dn"

  defp get_wsse_header_data(user, password) do
    nonce = generate_nonce(20, []) |> to_string
    created = format_date_time(:erlang.localtime)
    digest = :crypto.hash(:sha, nonce <> created <> password) |> to_string
    {user, Base.encode64(digest), Base.encode64(nonce), created}
  end

  defp format_date_time({{year, month, day}, {hour, minute, second}}) do
    :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [year, month, day, hour, minute, second]) |> List.flatten |> to_string
  end

  defp generate_nonce(0,l) do
    l ++ [:rand.uniform(255)]
  end

  defp generate_nonce(n,l) do
    generate_nonce(n - 1, l ++ [:rand.uniform(255)])
  end

  #### XML Parsing

  defp parse_elements(event_elements) do
    [response] =
      case event_elements do
        [] -> ["No ptz controls found on this Camera!"]
        _ ->
          Enum.map(event_elements, fn(event_element) ->
            parse(xmlElement(event_element, :content))
          end)
      end

    cond do
      is_bitstring(response) == true -> response
      Map.size(response) == 0 -> :ok
      true -> response
    end
  end

  defp parse(element) do
    cond do
      Record.is_record(element, :xmlElement) ->
        name = case xmlElement(element, :name) |> to_string |> String.split(":") do
                 [_ns,name] -> name
                 [name] -> name
               end
        content = xmlElement(element, :content)
        case xmlElement(element, :attributes) do
          [] -> Map.put(%{}, name, parse(content))
          attributes ->  case parse(content) do
                           value when is_map(value) -> Map.put(%{}, name, value |> Map.merge(parse(attributes)))
                           value -> Map.put(%{}, name, value)
                         end
        end
      Record.is_record(element, :xmlAttribute) ->
        name = xmlAttribute(element, :name) |> to_string
        value = xmlAttribute(element, :value) |> to_string
        Map.put(%{}, name, value)

      Record.is_record(element, :xmlText) ->
        case xmlText(element, :value) |> to_string do
          "\n" -> %{}
          value -> Map.put(%{}, "#text", value)
        end

      is_list(element) ->
        case Enum.map(element, &(parse(&1))) do
          [text_content] when is_map(text_content) ->
            Map.get(text_content, "#text", text_content)

          elements ->
            Enum.reduce(elements, %{}, fn(x, acc) ->
              if is_map(x) do
                Map.merge(acc, x, fn(_key, v1, v2) ->
                  case v1 do
                    nil -> v2
                    v when is_list(v) -> v ++ [v2]
                    _ -> [v1, v2]
                  end
                end)
              else
                acc
              end
            end)
        end
      true -> "Not supported to parse #{inspect element}"
    end
  end
end
