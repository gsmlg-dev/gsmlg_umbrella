ExUnit.start()
# Note: GSMLG.AWS is started by GSMLG.Application, no need to start it here
# when running tests from the umbrella root. Only start if not already running.
case Process.whereis(GSMLG.AWS.Finch) do
  nil -> GSMLG.AWS.start_link([])
  _pid -> :ok
end
