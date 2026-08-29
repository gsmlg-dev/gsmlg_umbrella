defmodule GSMLG.AdminWeb.ClientCertificate do
  @max_der_size 16 * 1024
  @max_base64_size 4 * div(@max_der_size + 2, 3)

  @subject_header "x-client-cert-subject"
  @certificate_header "x-client-cert-certificate-pem"
  @email_header "x-client-cert-email"
  @headers [@subject_header, @certificate_header, @email_header]

  defstruct [:certificate_der, :fingerprint, :pem, :subject, :email]

  def parse_conn(conn), do: parse_headers(conn.req_headers)

  def parse_headers(headers) do
    with {:ok, grouped} <- collect_headers(headers) do
      counts = Enum.map(@headers, &length(Map.get(grouped, &1, [])))

      cond do
        Enum.all?(counts, &(&1 == 0)) ->
          {:error, :missing_headers}

        Enum.any?(counts, &(&1 > 1)) ->
          {:error, :duplicate_header}

        not Enum.all?(counts, &(&1 == 1)) ->
          {:error, :incomplete_headers}

        true ->
          subject = hd(grouped[@subject_header])
          encoded = hd(grouped[@certificate_header])
          email = hd(grouped[@email_header])

          cond do
            String.trim(subject) == "" or String.trim(email) == "" -> {:error, :blank_header}
            encoded != "" and String.trim(encoded) == "" -> {:error, :blank_header}
            true -> parse_certificate(encoded, subject, email)
          end
      end
    end
  end

  defp collect_headers(headers) when is_list(headers) do
    Enum.reduce_while(headers, {:ok, %{}}, fn
      {name, value}, {:ok, acc} when is_binary(name) and is_binary(value) ->
        if String.valid?(name) and String.valid?(value) do
          key = String.downcase(name)

          grouped =
            if key in @headers, do: Map.update(acc, key, [value], &[value | &1]), else: acc

          {:cont, {:ok, grouped}}
        else
          {:halt, {:error, :invalid_header}}
        end

      _, _ ->
        {:halt, {:error, :invalid_header}}
    end)
  end

  defp collect_headers(_headers), do: {:error, :invalid_header}

  defp parse_certificate(encoded, _subject, _email) when byte_size(encoded) > @max_base64_size,
    do: {:error, :certificate_too_large}

  defp parse_certificate(encoded, subject, email) do
    case Base.decode64(encoded) do
      :error ->
        {:error, :invalid_base64}

      {:ok, der} ->
        if Base.encode64(der) != encoded do
          {:error, :invalid_base64}
        else
          case der do
            <<>> ->
              {:error, :empty_certificate}

            der when byte_size(der) > @max_der_size ->
              {:error, :certificate_too_large}

            der ->
              with :ok <- validate_x509(der) do
                {:ok,
                 %__MODULE__{
                   certificate_der: der,
                   fingerprint: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower),
                   pem: :public_key.pem_encode([{:Certificate, der, :not_encrypted}]),
                   subject: subject,
                   email: email
                 }}
              end
          end
        end
    end
  end

  defp validate_x509(der) do
    try do
      certificate = :public_key.pkix_decode_cert(der, :otp)

      case :public_key.pkix_encode(:OTPCertificate, certificate, :otp) do
        ^der -> :ok
        _ -> {:error, :invalid_certificate}
      end
    catch
      _, _ -> {:error, :invalid_certificate}
    end
  end
end
