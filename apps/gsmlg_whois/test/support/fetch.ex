defmodule Mix.Tasks.Gsmlg.Whois.Fetch do
  def run(domains) do
    root = Path.expand("../fixtures/raw", __DIR__)
    File.mkdir_p!(root)

    for domain <- domains do
      {:ok, output} = GSMLG.Whois.lookup_domain_raw(domain)
      path = Path.join(root, domain)
      File.write!(path, output)
      IO.puts("[✓] #{domain}: wrote #{byte_size(output)} bytes to #{path}")
    end
  end
end
