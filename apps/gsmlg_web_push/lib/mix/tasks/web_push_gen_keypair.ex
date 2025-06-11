defmodule Mix.Tasks.WebPush.Gen.Keypair do
  def run(_) do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)

    IO.puts("""
    # Put the following in your config.exs:

    config :web_push_encryption, :vapid_details,
      subject: "mailto:administrator@gsmlg.com",
      public_key: "#{ub64(public)}",
      private_key: "#{ub64(private)}"

    """)
  end

  defp ub64(value) do
    Base.url_encode64(value, padding: false)
  end
end
