defmodule Guardian.Plug do
  @moduledoc """
  Guardian.Plug contains functions that assist with interacting with Guardian via Plugs.

  Guardian.Plug is not itself a plug.

  ## Example

      Guardian.Plug.sign_in(conn, user)
      Guardian.Plug.sign_in(conn, user, :token)
      Guardian.Plug.sign_in(conn, user, :token, %{ claims: "i", make: true, key: :secret }) # stores this JWT in a different location (keyed by :secret)


  ## Example

      Guardian.Plug.sign_out(conn) # sign out all sessions
      Guardian.Plug.sign_out(conn, :secret) # sign out only the :secret session
  """

  import Guardian.Keys

  @doc """
  A simple check to see if a request is authenticated
  """
  @spec authenticated?(Plug.Conn.t) :: atom # boolean
  def authenticated?(conn), do: authenticated?(conn, :default)

  @doc """
  A simple check to see if a request is authenticated
  """
  @spec authenticated?(Plug.Conn.t, atom) :: atom # boolean
  def authenticated?(conn, type) do
    case claims(conn, type) do
      { :error, _ } -> false
      nil -> false
      _ -> true
    end
  end

  @doc """
  Sign in a resource (that your configured serializer knows about) into the current web session.
  """
  @spec sign_in(Plug.Conn.t, any) :: Plug.Conn.t
  def sign_in(conn, object), do: sign_in(conn, object, nil, %{})

  @doc """
  Sign in a resource (that your configured serializer knows about) into the current web session.

  By specifying the 'type' of the token, you're setting the aud field in the JWT.
  """
  @spec sign_in(Plug.Conn.t, any, atom | String.t) :: Plug.Conn.t
  def sign_in(conn, object, type), do: sign_in(conn, object, type, %{})

  @doc false
  def sign_in(conn, object, type, claims) when is_list(claims), do: sign_in(conn, object, type, Enum.into(claims, %{}))

  @doc """
  Same as sign_in/3 but also encodes all claims into the JWT.

  The `:key` key in the claims map is special in that it sets the location of the storage.

  The :perms key will provide the ability to encode permissions into the token. The value at :perms should be a map

  ### Example

      Guaridan.sign_in(conn, user, :token, perms: %{ default: [:read, :write] })

  """
  @spec sign_in(Plug.Conn.t, any, atom | String.t, Map) :: Plug.Conn.t
  def sign_in(conn, object, type, claims) do
    the_key = Map.get(claims, :key, :default)
    claims = Map.delete(claims, :key)

    case Guardian.encode_and_sign(object, type, claims) do
      { :ok, jwt, full_claims } ->
        conn
        |> Plug.Conn.put_session(base_key(the_key), jwt)
        |> set_current_resource(object, the_key)
        |> set_claims(full_claims, the_key)
        |> set_current_token(jwt, the_key)
        |> Guardian.hooks_module.after_sign_in(the_key)

      { :error, reason } -> Plug.Conn.put_session(conn, base_key(the_key), { :error, reason }) # TODO: handle this failure
    end
  end

  @doc """
  Sign out of a session.

  If no key is specified, the entire session is cleared.  Otherwise, only the
  location specified is cleared
  """
  @spec sign_out(Plug.Conn.t) :: Plug.Conn.t
  def sign_out(conn, the_key \\ :all) do
    conn
    |> Guardian.hooks_module.before_sign_out(the_key)
    |> sign_out_via_key(the_key)
  end

  @doc """
  Fetch the currently verified claims from the current request
  """
  @spec claims(Plug.Conn.t, atom) :: { :ok, Map } | { :error, atom | String.t }
  def claims(conn, the_key \\ :default) do
    case conn.assigns[claims_key(the_key)] do
      { :ok, claims } -> { :ok, claims }
      { :error, reason } -> { :error, reason }
      _ -> { :error, :no_session }
    end
  end

  @doc false
  @spec set_claims(Plug.Conn.t, { :ok, Map }, atom) :: Plug.Conn.t
  def set_claims(conn, claims, the_key \\ :default) do
    Plug.Conn.assign(conn, claims_key(the_key), claims)
  end

  @doc """
  Fetch the currently authenticated resource if loaded, optionally located at a location (key)
  """
  @spec current_resource(Plug.Conn.t, atom) :: any | nil
  def current_resource(conn, the_key \\ :default) do
    conn.assigns[resource_key(the_key)]
  end

  @doc false
  def set_current_resource(conn, resource, the_key \\ :default) do
    Plug.Conn.assign(conn, resource_key(the_key), resource)
  end

  @doc """
  Fetch the currently verified token from the request. optionally located at a location (key)
  """
  @spec current_token(Plug.Conn.t, atom) :: String.t | nil
  def current_token(conn, the_key \\ :default) do
    conn.assigns[jwt_key(the_key)]
  end

  @doc false
  def set_current_token(conn, jwt, the_key \\ :default) do
    Plug.Conn.assign(conn, jwt_key(the_key), jwt)
  end

  defp sign_out_via_key(conn, :all) do
    conn
    |> Plug.Conn.clear_session
    |> clear_jwt_assign(:all)
    |> clear_resource_assign(:all)
    |> clear_claims_assign(:all)
  end

  defp sign_out_via_key(conn, the_key) do
    Plug.Conn.delete_session(conn, claims_key(the_key))
    |> clear_jwt_assign(the_key)
    |> clear_resource_assign(the_key)
    |> clear_claims_assign(the_key)
  end

  defp clear_resource_assign(conn, :all) do
    Map.keys(conn.assigns)
    |> Enum.filter(&(String.starts_with?(to_string(&1), "guardian_") && String.ends_with?(to_string(&1), "_resource")))
    |> Enum.reduce(conn, fn(key, c) -> clear_resource_assign(c, key_from_other(key)) end)
  end

  defp clear_resource_assign(conn, key), do: Plug.Conn.assign(conn, resource_key(key), nil)

  defp clear_claims_assign(conn, :all) do
    Map.keys(conn.assigns)
    |> Enum.filter(&(String.starts_with?(to_string(&1), "guardian_") && String.ends_with?(to_string(&1), "_claims")))
    |> Enum.reduce(conn, fn(key, c) -> clear_claims_assign(c, key_from_other(key)) end)
  end

  defp clear_claims_assign(conn, key), do: Plug.Conn.assign(conn, claims_key(key), nil)

  defp clear_jwt_assign(conn, :all) do
    Map.keys(conn.assigns)
    |> Enum.filter(&(String.starts_with?(to_string(&1), "guardian_") && String.ends_with?(to_string(&1), "_jwt")))
    |> Enum.reduce(conn, fn(key, c) -> clear_jwt_assign(c, key_from_other(key)) end)
  end

  defp clear_jwt_assign(conn, key) do
    jwt = current_token(conn, key)
    case claims(conn, key) do
      { :ok, the_claims } -> Guardian.revoke!(jwt, the_claims)
      _ -> :ok
    end
    Plug.Conn.assign(conn, jwt_key(key), nil)
  end
end
