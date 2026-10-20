# GSMLG.AWS

AWS helpers for S3 objects, Route53 DNS records and DynamoDB tables. Requests use
the AWS SDK through a Tesla/Finch transport; selected listing calls use Cachex.

## Installation

Add the package to your dependencies:

```elixir
{:gsmlg_aws, "~> 1.0"}
```

The package follows the GSMLG umbrella release version. Inside this repository,
use `{:gsmlg_aws, in_umbrella: true}` instead.

## Usage

Add `{GSMLG.AWS, []}` to your supervision tree to start the cache and Finch pool.
Supply credentials under a named provider in application configuration:

```elixir
config :gsmlg_aws, :aws_credentials, %{
  "default" => %{
    access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
    region: System.fetch_env!("AWS_REGION")
  }
}
```

Call `GSMLG.AWS.S3.list_buckets/0`, `GSMLG.AWS.Route53.list_hosted_zones/0`
or `GSMLG.AWS.DynamoDB.list_tables/0`. Use
`GSMLG.AWS.Client.get_client("provider_name")` to construct a client from another
configured provider.

## License

MIT; see [LICENSE](LICENSE).

