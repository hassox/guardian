defmodule Guardian do
  @moduledoc """
  A module that provides JWT based authentication for Elixir applications.

  Guardian provides the framework for using JWT any elixir application, web based or otherwise,
  Where authentication is required.

  The base unit of authentication currency is implemented using JWTs.

  ## Configuration

      config :guardian, Guardian,
        allowed_algos: ["HS512", "HS384"],
        issuer: "MyApp",
        ttl: { 30, :days },
        serializer: MyApp.GuardianSerializer,
        secret_key: "lksjdlkjsdflkjsdf"

  """
  import Guardian.Utils

  @default_algos ["HS512"]

  if !Application.get_env(:guardian, Guardian), do: raise "Guardian is not configured"
  if !Keyword.get(Application.get_env(:guardian, Guardian), :serializer), do: raise "Guardian requires a serializer"

  @doc """
  Encode and sign a JWT from a resource. The resource will be run through the configured serializer to obtain a value suitable for storage inside a JWT.
  """
  @spec encode_and_sign(any) :: { :ok, String.t, Map } | { :error, atom } | { :error, String.t }
  def encode_and_sign(object), do: encode_and_sign(object, nil, %{})

  @doc """
  Like encode_and_sign/1 but also accepts the type (encoded to the typ key) for the JWT

  The type can be anything but suggested is "token".
  """
  @spec encode_and_sign(any, atom | String.t) :: { :ok, String.t, Map } | { :error, atom } | { :error, String.t }
  def encode_and_sign(object, type), do: encode_and_sign(object, type, %{})

  @doc false
  def encode_and_sign(object, type, claims) when is_list(claims), do: encode_and_sign(object, type, Enum.into(claims, %{}))

  @doc """
  Like encode_and_sign/2 but also encode anything found inside the claims map into the JWT.

  To encode permissions into the token, use the `:perms` key and pass it a map with the relevant permissions (must be configured)

  ### Example

      Guardian.encode_and_sign(user, :token, perms: %{ default: [:read, :write] })
  """
  @spec encode_and_sign(any, atom | String.t, Map) :: { :ok, String.t, Map } | { :error, atom } | { :error, String.t }
  def encode_and_sign(object, type, claims) do
    with {:ok, claims} <- build_claims(object, type, claims),
         {:ok, {object, type, claims}} <- call_before_encode_and_sign_hook(object, type, claims),
         {:ok, jwt} <- encode_claims(claims),
         call_after_encode_and_sign_hook(object, type, claims, jwt),
         do: { :ok, jwt, claims }
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
      { :ok, claims } -> revoke!(jwt, claims)
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
  Refresh the token. The token will be renewed and receive a new:

  * `jti` - JWT id
  * `iat` - Issued at
  * `exp` - Expiry time.
  * `nbf` - Not valid before time

  The current token will be revoked when the new token is successfully created.

  Note: A valid token must be used in order to be refreshed.
  """
  @spec refresh!(String.t) :: {:ok, String.t, Map.t} | {:error, any}
  def refresh!(jwt) do
    case decode_and_verify(jwt) do
      {:ok, claims} -> refresh!(jwt, claims)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  As refresh!/1 but allows the claims to be updated. Specifically useful is the ability to set the ttl of the token.

      Guardian.refresh(existing_jwt, existing_claims, %{ttl: { 5, :minutes}})

  Once the new token is created, the old one will be revoked.
  """
  @spec refresh!(String.t, Map.t, Map.t) :: {:ok, String.t, Map.t} | {:error, any}
  def refresh!(_jwt, claims, params \\ %{}) do
    params = Enum.into(params, %{})
    new_claims = Map.drop(claims, ["jti", "iat", "exp", "nbf"])
    |> Map.merge(params)
    |> Guardian.Claims.jti
    |> Guardian.Claims.nbf
    |> Guardian.Claims.iat
    |> Guardian.Claims.ttl

    type = Map.get(new_claims, "typ")

    {:ok, resource} = Guardian.serializer.from_token(Map.get(new_claims, "sub"))

    case encode_and_sign(resource, type, new_claims) do
      {:ok, jwt, full_claims} ->
        revoke!(jwt, claims)
        {:ok, jwt, full_claims}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetch the configured serializer module
  """
  @spec serializer() :: Module.t
  def serializer, do: config(:serializer)

  @doc """
  Verify the given JWT. This will decode_and_verify via `decode_and_verify/2` with
  no expected claims

    * `jwt` - JWT to decode
  """
  @spec decode_and_verify(String.t) :: { :ok, Map } | { :error, atom } | { :error, String.t }
  def decode_and_verify(jwt), do: decode_and_verify(jwt, %{})


  @doc """
  Decode and verify the given JWT.

    * `jwt` - JWT to decode
    * `expected_claims` - Claims that are expected to be present
  """
  @spec decode_and_verify(String.t, Map) :: { :ok, Map } | { :error, atom | String.t }
  def decode_and_verify(jwt, expected_claims) do
    expected_claims = build_expected_claims(expected_claims)

    try do
      with {:ok, claims} <- decode_token(jwt),
           {:ok, claims} <- verify_claims(claims, expected_claims),
           {:ok, {claims, _}} <- Guardian.hooks_module.on_verify(claims, jwt),
           do: {:ok, claims}
    rescue
      e ->
        { :error, e }
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
  def config(key), do: Keyword.get(config, key)
  @doc false
  def config(key, default), do: Keyword.get(config, key, default)

  defp jose_jws do
    %{ "alg" => hd(allowed_algos) }
  end
  defp jose_jwk, do: %{ "kty" => "oct", "k" => :base64url.encode(config(:secret_key)) }

  defp encode_claims(claims) do
    { _, token } = JOSE.JWT.sign(jose_jwk, jose_jws, claims) |> JOSE.JWS.compact
    { :ok, token }
  end

  defp decode_token(token) do
    case JOSE.JWT.verify_strict(jose_jwk, allowed_algos, token) do
      { true, jose_jwt, _ } ->  { :ok, jose_jwt.fields }
      { false, _, _ } -> { :error, :invalid_token }
    end
  end

  defp allowed_algos, do: config(:allowed_algos, @default_algos)

  def verify_claims(claims, params) do
    verify_claims claims, Map.keys(claims), config(:verify_module, Guardian.JWT), params
  end

  defp verify_claims(claims, [h | t], module, params) do
    case apply(module, :validate_claim, [h, claims, params]) do
      :ok -> verify_claims(claims, t, module, params)
      { :error, reason } -> { :error, reason }
    end
  end

  defp verify_claims(claims, [], _, _), do: { :ok, claims }

  defp build_claims(object, type, claims) do
    case Guardian.serializer.for_token(object) do
      { :ok, sub } ->
        full_claims = claims
          |> stringify_keys
          |> set_permissions
          |> Guardian.Claims.app_claims
          |> Guardian.Claims.typ(type)
          |> Guardian.Claims.sub(sub)
          |> set_aud_if_nil(sub)

        {:ok, full_claims}
      {:error, reason} ->  {:error, reason}
    end
  end

  defp build_expected_claims(expected_claims) do
    expected_claims = stringify_keys(expected_claims)

    if verify_issuer? do
      expected_claims = Map.put_new(expected_claims, "iss", issuer)
    end

    expected_claims
  end

  defp call_before_encode_and_sign_hook(object, type, claims) do
    Guardian.hooks_module.before_encode_and_sign(object, type, claims)
  end

  defp call_after_encode_and_sign_hook(resource, type, claims, jwt) do
    Guardian.hooks_module.after_encode_and_sign(resource, type, claims, jwt)
  end

  defp set_permissions(claims) do
    perms = Map.get(claims, "perms", %{})
    Guardian.Claims.permissions(claims, perms) |> Map.delete("perms")
  end

  def set_aud_if_nil(claims, value) do
    if Map.get(claims, "aud") == nil do
      claims = Guardian.Claims.aud(claims, value)
    end
    claims
  end
end
