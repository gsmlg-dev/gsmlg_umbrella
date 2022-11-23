defmodule GSMLG.GeoIP2 do
  use HTTPoison.Base

  @supported_languages ~w(
    pt-BR en ja ru fr es zh-CN de
  )

  def process_request_url(url) do
    "https://geoip.gsmlg.org" <> url
  end

  def process_response_body(body) do
    body
    |> Jason.decode!([{:keys, :atoms}])
  end

  def langs() do
    @supported_languages
  end

  def get_ip_info(ip, lang \\ "en") do
    lang =
      if Enum.member?(@supported_languages, lang) do
        lang
      else
        "en"
      end

    case get("/", [], params: %{"ip" => ip, "lang" => lang}) do
      {:ok, %HTTPoison.Response{status_code: 200, body: ipInfo}} ->
        ipInfo

      any ->
        IO.puts(">>>>>>")
        IO.inspect(any)
        %{}
    end
  end
end
