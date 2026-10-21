defmodule GSMLG.Web.Hologram.Pages.Whois do
  use Hologram.Page

  alias GSMLG.Web.Hologram.Messages

  route("/toolbox/whois")
  layout(GSMLG.Web.Hologram.Shell)

  def init(_params, component, server) do
    component
    |> Messages.init(server)
    |> put_state(loading: false, result: nil, error: nil, protocol: "whois")
  end

  def action(:lookup, params, component) do
    component
    |> put_state(loading: true, result: nil, error: nil)
    |> put_command(:lookup,
      look_for: String.trim(params.event["look_for"]),
      protocol: params.event["protocol"]
    )
  end

  def action(:protocol_changed, %{protocol: protocol}, component) do
    put_state(component, protocol: protocol)
  end

  def action(:loaded, params, component) do
    put_state(component, loading: false, result: params.result, error: nil)
  end

  def action(:failed, params, component) do
    error = if is_atom(params.error), do: component.state.text[params.error], else: params.error
    put_state(component, loading: false, result: nil, error: error)
  end

  def command(:lookup, %{look_for: query, protocol: protocol} = params, server)
      when is_binary(query) and byte_size(query) in 1..253 and protocol in ["whois", "rdap"] do
    if String.trim(query) == "" or Regex.match?(~r/[\x00-\x1f\x7f]/, query) do
      put_action(server, :failed, error: :invalid_input)
    else
      lookup(protocol, query, params, server)
    end
  end

  def command(:lookup, _params, server), do: put_action(server, :failed, error: :invalid_input)

  defp lookup("whois", query, _params, server) do
    case GSMLG.Whois.lookup_raw(query) do
      {:ok, entries} ->
        data =
          entries |> Enum.reverse() |> Enum.map(fn {host, info} -> %{host: host, info: info} end)

        put_action(server, :loaded, result: %{protocol: "whois", data: data})

      {:error, reason} ->
        put_action(server, :failed, error: inspect(reason))
    end
  end

  defp lookup("rdap", query, params, server) do
    type =
      case Map.get(params, :type, "domain") do
        "ip" -> :ip
        "asn" -> :asn
        _ -> :domain
      end

    case GSMLG.Whois.rdap_lookup(query, type: type) do
      {:ok, data} ->
        put_action(server, :loaded, result: %{protocol: "rdap", data: rdap_view(data)})

      {:error, reason} ->
        put_action(server, :failed, error: inspect(reason))
    end
  end

  @doc false
  def rdap_view(data) when is_map(data) do
    %{
      name: text(data["ldhName"]) || text(data["handle"]) || text(data["name"]) || "",
      kind: text(data["objectClassName"]) || "",
      handle: text(data["handle"]) || "",
      status: strings(data["status"]),
      events:
        Enum.map(maps(data["events"]), fn event ->
          %{action: text(event["eventAction"]), date: text(event["eventDate"])}
        end),
      nameservers:
        data["nameservers"] |> maps() |> Enum.map(&text(&1["ldhName"])) |> Enum.reject(&is_nil/1),
      dnssec: dnssec_view(data["secureDNS"]),
      entities: Enum.map(maps(data["entities"]), &entity_view/1),
      links:
        data["links"]
        |> maps()
        |> Enum.filter(&(&1["rel"] == "self"))
        |> Enum.map(&safe_url(&1["href"]))
        |> Enum.reject(&is_nil/1)
    }
  end

  def rdap_view(_data), do: rdap_view(%{})

  defp dnssec_view(data) when is_map(data) do
    %{
      signed: data["delegationSigned"] == true,
      records:
        Enum.map(maps(data["dsData"]), fn record ->
          %{
            key_tag: text(record["keyTag"]),
            algorithm: text(record["algorithm"]),
            digest_type: text(record["digestType"]),
            digest: text(record["digest"])
          }
        end)
    }
  end

  defp dnssec_view(_data), do: nil

  defp entity_view(entity) do
    %{
      name: vcard_field(entity, "fn") || text(entity["handle"]) || "",
      roles: entity["roles"] |> strings() |> Enum.join(", "),
      public_ids:
        Enum.map(maps(entity["publicIds"]), fn id ->
          %{type: text(id["type"]), identifier: text(id["identifier"])}
        end),
      abuse: abuse_contacts([entity])
    }
  end

  defp abuse_contacts(entities) do
    Enum.flat_map(entities, fn entity ->
      email = if "abuse" in strings(entity["roles"]), do: vcard_field(entity, "email")
      own = if is_binary(email), do: [email], else: []
      own ++ abuse_contacts(maps(entity["entities"]))
    end)
  end

  defp vcard_field(entity, key) do
    case entity["vcardArray"] do
      ["vcard", fields] when is_list(fields) ->
        Enum.find_value(fields, fn
          [^key, _params, _type, value] when is_binary(value) -> value
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp safe_url(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp safe_url(_url), do: nil

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
  defp maps(value), do: value |> list() |> Enum.filter(&is_map/1)
  defp strings(value), do: value |> list() |> Enum.filter(&is_binary/1)
  defp text(value) when is_binary(value) or is_number(value), do: value
  defp text(_value), do: nil

  def template do
    ~HOLO"""
    <section class="container mx-auto px-6 my-12">
      <h1 class="text-4xl font-bold mb-8">{@text.whois}</h1>
      <form id="whois-form" $submit="lookup" class="flex flex-col gap-4 max-w-sm mx-auto">
        <fieldset class="flex gap-4">
          <legend class="sr-only">{@text.protocol}</legend>
          <label class="flex items-center gap-2"><input type="radio" name="protocol" value="whois" checked={@protocol == "whois"} $change={:protocol_changed, protocol: "whois"} class="radio radio-primary" /> WHOIS</label>
          <label class="flex items-center gap-2"><input type="radio" name="protocol" value="rdap" checked={@protocol == "rdap"} $change={:protocol_changed, protocol: "rdap"} class="radio radio-primary" /> RDAP</label>
        </fieldset>
        <label for="whois-input">{@text.query}</label>
        <input id="whois-input" name="look_for" class="input input-primary w-full" required maxlength="253" />
        <button id="whois-submit" type="submit" class="btn btn-primary" disabled={@loading}>
          {%if @loading}{@text.loading}{%else}{@text.lookup}{/if}
        </button>
      </form>
      <div id="whois-result" class="flex flex-col gap-4 w-full my-6" aria-live="polite" aria-busy={@loading}>
        {%if @loading}<div role="status" class="animate-pulse rounded-xl bg-base-200 p-8">{@text.loading}</div>{/if}
        {%if @error}<div role="alert" class="alert alert-error">{@text.error}: {@error}</div>{/if}
        {%if @result}
          {%if @result.protocol == "whois"}
            {%for entry <- @result.data}
              <article class="card border border-base-300">
                <div class="card-body"><h2 class="card-title text-secondary">{entry.host}</h2><pre class="whitespace-pre-wrap break-words">{entry.info}</pre></div>
              </article>
            {/for}
          {%else}
            <article class="card border border-base-300">
              <div class="card-body gap-3">
                <h2 class="card-title font-mono text-2xl">{@result.data.name}</h2>
                <span class="font-mono text-sm">{@result.data.handle}</span>
                <span class="badge badge-primary">{@result.data.kind}</span>
                <div class="flex flex-wrap gap-2">
                  {%for status <- @result.data.status}<span class="badge badge-primary">{status}</span>{/for}
                </div>
              </div>
            </article>
            {%if @result.data.events != []}
              <article class="card border border-base-300">
                <div class="card-body"><h3 class="card-title">{@text.timeline}</h3>
                  <dl class="grid grid-cols-1 md:grid-cols-2 gap-3">
                    {%for event <- @result.data.events}<div class="rounded-lg bg-base-200 p-3"><dt class="font-semibold">{event.action}</dt><dd>{event.date}</dd></div>{/for}
                  </dl>
                </div>
              </article>
            {/if}
            {%if @result.data.nameservers != []}
              <article class="card border border-base-300"><div class="card-body"><h3 class="card-title">{@text.nameservers}</h3><ul>{%for name <- @result.data.nameservers}<li class="font-mono">{name}</li>{/for}</ul></div></article>
            {/if}
            {%if @result.data.dnssec}
              <article class="card border border-base-300"><div class="card-body">
                <h3 class="card-title">{@text.dnssec}</h3>
                <span class="badge">{%if @result.data.dnssec.signed}{@text.signed}{%else}{@text.unsigned}{/if}</span>
                {%for record <- @result.data.dnssec.records}
                  <dl class="rounded-lg bg-base-200 p-3 font-mono text-sm break-all">
                    <dt>{@text.key_tag}</dt><dd>{record.key_tag}</dd><dt>{@text.algorithm}</dt><dd>{record.algorithm}</dd><dt>{@text.digest}</dt><dd>{record.digest}</dd>
                  </dl>
                {/for}
              </div></article>
            {/if}
            {%for entity <- @result.data.entities}
              <article class="card border border-base-300"><div class="card-body">
                <h3 class="card-title">{entity.name}</h3><p>{entity.roles}</p>
                {%for id <- entity.public_ids}<p class="font-mono text-sm">{id.type}: {id.identifier}</p>{/for}
                {%for email <- entity.abuse}<p>{@text.abuse_contact}: {email}</p>{/for}
              </div></article>
            {/for}
            <div class="flex flex-wrap gap-2">
              {%for url <- @result.data.links}<a href={url} target="_blank" rel="noopener noreferrer" class="btn btn-sm btn-ghost font-mono break-all">{url}</a>{/for}
            </div>
          {/if}
        {/if}
      </div>
    </section>
    """
  end
end
