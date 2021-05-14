defmodule Conjure.HTTP do
  alias Conjure.Request

  def head(100), do: response("100 Continue")
  def head(502), do: response("502 Bad Gateway")
  def head(504), do: response("504 Gateway Timeout")

  defp response(status) do
    """
    HTTP/1.1 #{status}\r
    \r
    """
  end

  def request(%Request{
        body: "",
        headers: headers,
        method: method,
        path: path,
        version: version
      }) do
    """
    #{method} #{path} HTTP/#{version |> Tuple.to_list() |> Enum.join(".")}\r
    #{for {key, value} <- headers, into: "", do: "#{key}: #{value}\r\n"}\r
    """
  end

  def request(%Request{body: body} = request) do
    """
    #{request(%{request | body: ""})}
    #{body}
    """
    |> String.trim_trailing("\n")
  end
end
