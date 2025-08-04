defmodule GSMLG.AdminWeb.Guardian.DBHooks do
  defmacro __using__([]) do
    quote do
      def after_encode_and_sign(resource, claims, token, _options) do
        with {:ok, _} <- Guardian.DB.after_encode_and_sign(resource, claims["typ"], claims, token) do
          {:ok, token}
        end
      end

      def on_verify(claims, token, _options) do
        with {:ok, _} <- Guardian.DB.on_verify(claims, token) do
          {:ok, claims}
        end
      end

      def on_refresh({old_token, old_claims}, {new_token, new_claims}, _options) do
        with {:ok, _, _} <-
               Guardian.DB.on_refresh({old_token, old_claims}, {new_token, new_claims}) do
          {:ok, {old_token, old_claims}, {new_token, new_claims}}
        end
      end

      def on_revoke(claims, token, _options) do
        with {:ok, _} <- Guardian.DB.on_revoke(claims, token) do
          {:ok, claims}
        end
      end

      def revoke_all(resource, claims) do
        with {:ok, sub} <- subject_for_token(resource, claims) do
          Guardian.DB.revoke_all(resource)
        end
      end
    end
  end
end
