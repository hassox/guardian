defmodule Guardian do
  @moduledoc """
  A module that provides JWT based authentication for Elixir applications.

  Guardian provides the framework for using JWT any elixir application, web based or otherwise,
  Where authentication is required.

  The base unit of authentication currency is implemented using JWTs.

  ## Configuration

      config :guardian, Guardian,
        issuer: "MyApp",
        ttl: { 30, :days },
        serializer: MyApp.GuardianSerializer,
        secret_key: "lksjdlkjsdflkjsdf"

  Guardian uses Joken, so you will also need to configure that.
  """
  import Guardian.Utils

  if !Application.get_env(:guardian, Guardian), do: raise "Guardian is not configured"
  if !Dict.get(Application.get_env(:guardian, Guardian), :serializer), do: raise "Guardian requires a serializer"

  @doc """
  Encode and sign a JWT from a resource. The resource will be run through the configured serializer to obtain a value suitable for storage inside a JWT.
  """
  @spec encode_and_sign(any) :: { :ok, String.t, Map } | { :error, atom } | { :error, String.t }
  def encode_and_sign(object), do: encode_and_sign(object, nil, %{})

  @doc """
  Like encode_and_sign/1 but also accepts the audience (encoded to the aud key) for the JWT

  The aud can be anything but suggested is "token".
  """
  @spec encode_and_sign(any, atom | String.t) :: { :ok, String.t, Map } | { :error, atom } | { :error, String.t }
  def encode_and_sign(object, audience), do: encode_and_sign(object, audience, %{})

  @doc false
  def encode_and_sign(object, audience, claims) when is_list(claims), do: encode_and_sign(object, audience, Enum.into(claims, %{}))

  @doc """
  Like encode_and_sign/2 but also encode anything found inside the claims map into the JWT.

  To encode permissions into the token, use the `:perms` key and pass it a map with the relevant permissions (must be configured)

  ### Example

      Guardian.encode_and_sign(user, :token, perms: %{ default: [:read, :write] })
  """
  @spec encode_and_sign(any, atom | String.t, Map) :: { :ok, String.t, Map } | { :error, atom } | { :error, String.t }
  def encode_and_sign(object, audience, claims) do
    claims = stringify_keys(claims)
    perms = Map.get(claims, "perms", %{})
    claims = Guardian.Claims.permissions(claims, perms) |> Map.delete("perms")

    case Guardian.serializer.for_token(object) do
      { :ok, sub } ->
        full_claims = Guardian.Claims.app_claims(claims)
        |> Guardian.Claims.aud(audience)
        |> Guardian.Claims.sub(sub)

        case Guardian.hooks_module.before_encode_and_sign(object, audience, full_claims) do
          { :error, reason } -> { :error, reason }
          { :ok, { resource, type, hooked_claims } } ->
            case Joken.encode(hooked_claims) do
              { :ok, jwt } ->
                Guardian.hooks_module.after_encode_and_sign(resource, type, hooked_claims, jwt)
                { :ok, jwt, hooked_claims }
              { :error, "Unsupported algorithm" } -> { :error, :unsupported_algorithm }
              { :error, "Error encoding to JSON" } -> { :error, :json_encoding_fail }
            end
        end
      { :error, reason } -> { :error, reason }
    end
  end

  @doc false
  def hooks_module, do: config(:hooks, Guardian.Hooks.Default)

  @doc """
  Revokes the current token.
  This provides a hook to revoke, the logic for revocation of belongs in a Guardian.Hook.on_revoke
  This function is less efficient that revoke!/2. If you have claims, you should use that.
  """
  def revoke!(jwt) do
    case decode_and_verify(jwt) do
      { :ok, { claims, _ } } -> revoke!(jwt, claims)
      _ -> :ok
    end
  end

  @doc """
  Revokes the current token.
  This provides a hook to revoke, the logic for revocation of belongs in a Guardian.Hook.on_revoke
  """
  def revoke!(jwt, claims) do
    case Guardian.hooks_module.on_revoke(claims, jwt) do
      { :ok, _ } -> :ok
      { :error, reason } -> { :error, reason }
    end
  end

  @doc """
  Fetch the configured serializer module
  """
  @spec serializer() :: Module.t
  def serializer, do: config(:serializer)

  @doc """
  Verify the given JWT. This will decode_and_verify via decode_and_verify/2
  """
  @spec decode_and_verify(String.t) :: { :ok, Map } | { :error, atom } | { :error, String.t }
  def decode_and_verify(jwt), do: decode_and_verify(jwt, %{})


  @doc """
  Verify the given JWT.
  """
  @spec decode_and_verify(String.t, Map) :: { :ok, Map } | { :error, atom | String.t }
  def decode_and_verify(jwt, params) do
    params = stringify_keys(params)
    if verify_issuer?, do: params = Map.put_new(params, "iss", issuer)
    params = stringify_keys(params)

    try do
      case Joken.decode(jwt, params) do
        { :ok, claims } ->
          case Guardian.hooks_module.on_verify(claims, jwt) do
            { :ok, { claims, _ } } -> { :ok, claims }
            { :error, reason } -> { :error, reason }
          end
        { :error, "Missing signature" } -> { :error, :missing_signature }
        { :error, "Invalid signature" } -> { :error, :invalid_signature }
        { :error, "Invalid JSON Web Token" } -> { :error, :invalid_jwt }
        { :error, "Token expired" } -> { :error, :token_expired }
        { :error, "Token not valid yet" } -> { :error, :token_not_yet_valid }
        { :error, "Invalid audience" } -> { :error, :invalid_audience }
        { :error, "Missing audience" } -> { :error, :invalid_audience }
        { :error, "Invalid issuer" } -> { :error, :invalid_issuer }
        { :error, "Missing issuer" } -> { :error, :invalid_issuer }
        { :error, "Invalid subject" } -> { :error, :invalid_subject }
        { :error, "Missing subject" } -> { :error, :invalid_subject }
        { :error, reason } -> { :error, reason }
      end
    rescue
      e ->
        IO.puts(Exception.format_stacktrace(System.stacktrace))
        { :error, e.message }
    end
  end

  @doc """
  If successfully verified, returns the claims encoded into the JWT. Raises otherwise
  """
  @spec decode_and_verify!(String.t) :: Map
  def decode_and_verify!(jwt), do: decode_and_verify!(jwt, %{})

  @doc """
  If successfully verified, returns the claims encoded into the JWT. Raises otherwise
  """
  @spec decode_and_verify!(String.t, Map) :: Map
  def decode_and_verify!(jwt, params) do
    case decode_and_verify(jwt, params) do
      { :ok, claims } -> claims
      { :error, reason } -> raise to_string(reason)
    end
  end

  @doc """
  The configured issuer. If not configured, defaults to the node that issued.
  """
  @spec issuer() :: String.t
  def issuer, do: config(:issuer, to_string(node))

  defp verify_issuer?, do: config(:verify_issuer, false)

  @doc false
  def config, do: Application.get_env(:guardian, Guardian)
  @doc false
  def config(key), do: Dict.get(config, key)
  @doc false
  def config(key, default), do: Dict.get(config, key, default)
end
