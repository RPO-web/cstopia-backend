defmodule CstopiaBackendWeb.Plugs.RemoteIp do
  @moduledoc """
  A plug that sets the remote_ip based on the X-Forwarded-For header.
  This is important for proper rate limiting when the application is behind a proxy.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded_for | _] ->
        # Get the first IP in the X-Forwarded-For chain, which is usually the client
        forwarded_ips =
          forwarded_for
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&(&1 != ""))

        case forwarded_ips do
          [client_ip | _] ->
            # Convert string IP to tuple format
            case parse_ip(client_ip) do
              {:ok, ip_tuple} -> %{conn | remote_ip: ip_tuple}
              _error -> conn
            end
          [] -> conn
        end
      [] -> conn
    end
  end

  # Parse IP address string to tuple format
  defp parse_ip(ip_string) do
    case :inet.parse_address(to_charlist(ip_string)) do
      {:ok, ip_tuple} -> {:ok, ip_tuple}
      {:error, _reason} -> :error
    end
  end
end
