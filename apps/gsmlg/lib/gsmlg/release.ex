defmodule GSMLG.Release do
  @app :gsmlg

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def reset_password(username_or_email, new_password) do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(GSMLG.Repo, fn _repo ->
        case GSMLG.Accounts.get_user_by_username_or_email(username_or_email) do
          nil ->
            IO.puts("Error: user not found for \"#{username_or_email}\"")

          user ->
            case GSMLG.Accounts.reset_password(user, new_password) do
              {:ok, _user} ->
                IO.puts("Password reset successfully for user \"#{user.username}\"")

              {:error, msg} when is_binary(msg) ->
                IO.puts("Error: #{msg}")

              {:error, changeset} ->
                IO.puts("Error: #{inspect(changeset.errors)}")
            end
        end
      end)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
