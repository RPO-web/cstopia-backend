defmodule CstopiaBackendWeb.RateLimiter do
  @moduledoc """
  Helpers for rate limiting requests with Hammer.
  """
  import Plug.Conn

  @doc """
  Function plug for general rate limiting: 60 requests per minute per IP.
  """
  def rate_limit_general(conn, _opts) do
    case check_rate(conn, "general", 60_000, 60) do
      {:allow, _count} ->
        conn
      {:deny, _limit} ->
        handle_rate_limit(conn, [])
    end
  end

  @doc """
  Function plug for stricter auth rate limiting: 10 requests per minute per IP.

    Helper function to check rate limits using the client's IP address.
  """
  def rate_limit_auth(conn, _opts) do
    case check_rate(conn, "auth", 60_000, 10) do
      {:allow, _count} ->
        conn
      {:deny, _limit} ->
        handle_rate_limit(conn, [])
    end
  end

  defp check_rate(conn, id_prefix, scale, limit) do
    # Extract IP as string from conn's remote_ip
    ip = conn.remote_ip
         |> :inet.ntoa()
         |> to_string()

    # Create a rate limit key by combining the prefix with the IP
    key = "#{id_prefix}:#{ip}"

    # Check the rate using Hammer
    Hammer.check_rate(key, scale, limit)
  end

  @doc """
  Custom error handler for rate-limited requests.

  Returns a 429 Too Many Requests status with a friendly error message.
  """
  def handle_rate_limit(conn, _opts) do
    conn
    |> put_resp_content_type("text/html")
    |> put_status(429)
    |> send_resp(429, """
    <!DOCTYPE html>
    <html>
    <head>
      <title>Rate Limited</title>
      <style>
        body {
          font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
          background-color: #f5f5f5;
          color: #333;
          text-align: center;
          padding: 50px;
          line-height: 1.6;
        }
        .container {
          max-width: 600px;
          margin: 0 auto;
          background-color: white;
          padding: 30px;
          border-radius: 8px;
          box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        h1 {
          color: #e53e3e;
          margin-bottom: 20px;
        }
        p {
          margin-bottom: 15px;
        }
      </style>
    </head>
    <body>
      <div class="container">
        <h1>Too Many Requests</h1>
        <p>You've made too many requests in a short period of time.</p>
        <p>Please wait a minute before trying again.</p>
        <p><a href="/">Return to Homepage</a></p>
      </div>
    </body>
    </html>
    """)
    |> halt()
  end
end
