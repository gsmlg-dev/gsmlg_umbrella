ExUnit.start()

# Start the ETS cache backend for tests (replaces the removed Application)
{:ok, _} = GSMLG.Whois.Cache.ETS.start_link([])
