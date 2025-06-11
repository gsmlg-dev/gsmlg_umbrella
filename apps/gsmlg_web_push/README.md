# GSMLG.WebPush

## GSMLG.WebPush.Encryption

Elixir implementation of [Web Push Payload encryption](https://developers.google.com/web/updates/2016/03/web-push-encryption?hl=en).

## Installation

1. Add `gsmlg_web_push` and a json library for jose to your list of dependencies in `mix.exs`.

  ```elixir
  def deps do
    [
      {:gsmlg_web_push, in_umbrella: true}
    ]
  end
  ```

2. Generate a web push Vapid keypair on the CLI and put it in your `config.exs` file:

```
 $ mix do deps.get, compile
 $ mix web_push.gen.keypair
```

## Usage

`GSMLG.WebPush.Encryption` has two public API:

* `GSMLG.WebPush.Encryption.encrypt/3`: Takes a body, a subscription, and an optional padding and returns a map containing `ciphertext`, `server_public_key` and `salt`.

* `GSMLG.WebPush.Encryption.send_web_push/3`: Takes a body, a subcription, and a GCM secret key and sends a push notification with the given payload.

```elixir
body = ~s({"hello": "elixir"})
subscription = %{keys: %{p256dh: "P256DH", auth: "AUTH" }, endpoint: "ENDPOINT"}
gcm_api_key = "API_KEY"

# encrypt the body
encrypted_body = GSMLG.WebPush.Encryption.encrypt(body, subscription)
# or just send the push
{:ok, response} = GSMLG.WebPush.Encryption.send_web_push(body, subscription, gcm_api_key)
```

See [the docs](https://hexdocs.pm/gsmlg_web_push) for more info.

## Client Sample

Client sample at `gsmlg_web` and `gsmlg_admin_web`.

## Credits

The implementation is ported from [googlechrome/web-push-encryption](https://github.com/GoogleChrome/web-push-encryption)
