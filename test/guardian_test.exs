defmodule GuardianTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Mock

  setup do
    claims = %{
      "aud" => "User:1",
      "typ" => "access",
      "exp" => Guardian.Utils.timestamp + 10_000,
      "iat" => Guardian.Utils.timestamp,
      "iss" => "MyApp",
      "sub" => "User:1",
      "something_else" => "foo"
    }

    claims_with_valid_jku = claims
      |> Map.merge(%{
        "jku" => "https://server.example/jwk/abcd",
        "kid" => "abcd"
      })

    claims_with_invalid_jku = claims
      |> Map.merge(%{
        "jku" => "https://bad.actor/jwk/abcd",
        "kid" => "abcd"
      })

    config = Application.get_env(:guardian, Guardian)
    algo = hd(Keyword.get(config, :allowed_algos))
    secret = Keyword.get(config, :secret_key)

    jose_jws = %{"alg" => algo}
    jose_jwk = %{"kty" => "oct", "k" => :base64url.encode(secret)}

    {_, jwt} = jose_jwk
                  |> JOSE.JWT.sign(jose_jws, claims)
                  |> JOSE.JWS.compact

    es512_jose_jwk = JOSE.JWK.generate_key({:ec, :secp521r1})
    es512_jose_jws = JOSE.JWS.from_map(%{"alg" => "ES512"})
    es512_jose_jwt = es512_jose_jwk
      |> JOSE.JWT.sign(es512_jose_jws, claims)
      |> JOSE.JWS.compact
      |> elem(1)

    es512_jose_jwt_with_valid_jku = es512_jose_jwk
      |> JOSE.JWT.sign(es512_jose_jws, claims_with_valid_jku)
      |> JOSE.JWS.compact
      |> elem(1)

    es512_jose_jwt_with_invalid_jku = es512_jose_jwk
      |> JOSE.JWT.sign(es512_jose_jws, claims_with_invalid_jku)
      |> JOSE.JWS.compact
      |> elem(1)

    es512_jose_jku_response = with pkey <- JOSE.JWK.to_public(es512_jose_jwk),
      {_, key} <- JOSE.JWK.to_map(pkey),
      do: Poison.encode!(key)

    mocks = [
      request: fn(verb, url, _headers, _body, _opts) ->
        cond do
          verb == :get && url =~ ~r{/jwk/abcd} ->
            {:ok, 200, [ content_type: "application/json" ], es512_jose_jku_response}
          true ->
            {:ok, 404, [], ""}
        end
      end,
      body: fn(value) -> {:ok, value} end,
    ]

    {
      :ok,
      %{
        claims: claims,
        claims_with_valid_jku: claims_with_valid_jku,
        jwt: jwt,
        jose_jws: jose_jws,
        jose_jwk: jose_jwk,
        es512: %{
          jwk: es512_jose_jwk,
          jws: es512_jose_jws,
          jwt: es512_jose_jwt,
          jwt_with_valid_jku: es512_jose_jwt_with_valid_jku,
          jwt_with_invalid_jku: es512_jose_jwt_with_invalid_jku,
          mocks: mocks
        }
      }
    }
  end

  test "no config" do
    cfg = Guardian.config
    Application.put_env(:guardian, Guardian, nil)
    assert_raise RuntimeError, "Guardian is not configured", &Guardian.config/0
    Application.put_env(:guardian, Guardian, cfg)
  end

  test "config with no serializer" do
    cfg = Guardian.config
    Application.put_env(:guardian, Guardian, Keyword.drop(cfg, [:serializer]))
    assert_raise RuntimeError, "Guardian requires a serializer", &Guardian.config/0
    Application.put_env(:guardian, Guardian, cfg)
  end

  test "config with a value" do
    assert Guardian.config(:issuer) == "MyApp"
  end

  test "config with no value" do
    assert Guardian.config(:not_a_thing) == nil
  end

  test "config with a default value" do
    assert Guardian.config(:not_a_thing, :this_is_a_thing) == :this_is_a_thing
  end

  test "config with a system value" do
    assert Guardian.config(:system_foo) == nil
    System.put_env("FOO", "foo")
    assert Guardian.config(:system_foo) == "foo"
  end

  test "it fetches the currently configured serializer" do
    assert Guardian.serializer == Guardian.TestGuardianSerializer
  end

  test "it returns the current app name" do
    assert Guardian.issuer == "MyApp"
  end

  test "it verifies the jwt", context do
    assert Guardian.decode_and_verify(context.jwt) == {:ok, context.claims}
  end

  test "it verifies the jwt with custom secret %JOSE.JWK{} struct", context do
    secret = context.es512.jwk
    assert Guardian.decode_and_verify(context.es512.jwt, %{secret: secret}) == {:ok, context.claims}
  end

  test "it verifies with an array of keys provided", context do
    secrets = [context.jose_jwk, context.es512.jwk]
    assert Guardian.decode_and_verify(context.es512.jwt, %{secret: secrets}) == {:ok, context.claims}
  end

  test "it verifies the jwt with public key in jku", context do
    with_mock :hackney, context.es512.mocks do
      assert Guardian.decode_and_verify(context.es512.jwt_with_valid_jku) == {:ok, context.claims_with_valid_jku}
    end
  end

  test "it rejects untrusted jku urls", context do
    with_mock :hackney, context.es512.mocks do
      assert Guardian.decode_and_verify(context.es512.jwt_with_invalid_jku) == {:error, :invalid_token}
    end
  end

  test "it verifies the jwt with custom secret tuple", context do
    secret = {Guardian.TestHelper, :secret_key_function, [context.es512.jwk]}
    assert Guardian.decode_and_verify(context.es512.jwt, %{secret: secret}) == {:ok, context.claims}
  end

  test "it verifies the jwt with custom secret map", context do
    secret = context.es512.jwk |> JOSE.JWK.to_map |> elem(1)
    assert Guardian.decode_and_verify(context.es512.jwt, %{secret: secret}) == {:ok, context.claims}
  end

  test "verifies the issuer", context do
    assert Guardian.decode_and_verify(context.jwt) == {:ok, context.claims}
  end

  test "fails if the issuer is not correct", context do
    claims = %{
      typ: "access",
      exp: Guardian.Utils.timestamp + 10_000,
      iat: Guardian.Utils.timestamp,
      iss: "not the issuer",
      sub: "User:1"
    }

    {_, jwt} = context.jose_jwk
                  |> JOSE.JWT.sign(context.jose_jws, claims)
                  |> JOSE.JWS.compact

    assert Guardian.decode_and_verify(jwt) == {:error, :invalid_issuer}
  end

  test "fails if the expiry has passed", context do
    claims = Map.put(context.claims, "exp", Guardian.Utils.timestamp - 10)
    {_, jwt} = context.jose_jwk
                  |> JOSE.JWT.sign(context.jose_jws, claims)
                  |> JOSE.JWS.compact

    assert Guardian.decode_and_verify(jwt) == {:error, :token_expired}
  end

  test "it is invalid if the typ is incorrect", context do
    response = Guardian.decode_and_verify(
      context.jwt,
      %{typ: "something_else"}
    )

    assert response == {:error, :invalid_type}
  end

  test "verify! with a jwt", context do
    assert Guardian.decode_and_verify!(context.jwt) == context.claims
  end

  test "verify! with a bad token", context do
    claims = Map.put(context.claims, "exp", Guardian.Utils.timestamp - 10)
    {_, jwt} = context.jose_jwk
                  |> JOSE.JWT.sign(context.jose_jws, claims)
                  |> JOSE.JWS.compact

    assert_raise(RuntimeError, fn() -> Guardian.decode_and_verify!(jwt) end)
  end

  test "serializer" do
    assert Guardian.serializer == Guardian.TestGuardianSerializer
  end

  test "encode_and_sign(object)" do
    {:ok, jwt, _} = Guardian.encode_and_sign("thinger")

    {:ok, claims} = Guardian.decode_and_verify(jwt)
    assert claims["typ"] == "access"
    assert claims["aud"] == "thinger"
    assert claims["sub"] == "thinger"
    assert claims["iat"]
    assert claims["exp"] > claims["iat"]
    assert claims["iss"] == Guardian.issuer
  end

  test "encode_and_sign(object, audience)" do
    {:ok, jwt, _} = Guardian.encode_and_sign("thinger", "my_type")

    {:ok, claims} = Guardian.decode_and_verify(jwt)
    assert claims["typ"] == "my_type"
    assert claims["aud"] == "thinger"
    assert claims["sub"] == "thinger"
    assert claims["iat"]
    assert claims["exp"] > claims["iat"]
    assert claims["iss"] == Guardian.issuer
  end

  test "encode_and_sign(object, type, claims)" do
    {:ok, jwt, _} = Guardian.encode_and_sign(
      "thinger",
      "my_type",
      some: "thing"
    )

    {:ok, claims} = Guardian.decode_and_verify(jwt)
    assert claims["typ"] == "my_type"
    assert claims["aud"] == "thinger"
    assert claims["sub"] == "thinger"
    assert claims["iat"]
    assert claims["exp"] > claims["iat"]
    assert claims["iss"] == Guardian.issuer
    assert claims["some"] == "thing"
  end

  test "encode_and_sign(object, aud) with ttl" do
    {:ok, jwt, _} = Guardian.encode_and_sign(
      "thinger",
      "my_type",
      ttl: {5, :days}
    )

    {:ok, claims} = Guardian.decode_and_verify(jwt)
    assert claims["exp"] == claims["iat"] + 5 * 24 * 60 * 60
  end

  test "encode_and_sign(object, aud) with ttl in claims" do
    claims = Guardian.Claims.app_claims
    |> Guardian.Claims.ttl({5, :days})

    {:ok, jwt, _} = Guardian.encode_and_sign("thinger", "my_type", claims)

    {:ok, claims} = Guardian.decode_and_verify(jwt)
    assert claims["exp"] == claims["iat"] + 5 * 24 * 60 * 60
  end

  test "encode_and_sign(object, aud) with ttl, number and period as binaries" do
    {:ok, jwt, _} = Guardian.encode_and_sign(
      "thinger",
      "my_type",
      ttl: {"5", "days"}
    )

    {:ok, claims} = Guardian.decode_and_verify(jwt)
    assert claims["exp"] == claims["iat"] + 5 * 24 * 60 * 60
  end

  test "encode_and_sign(object, aud) with ttl in claims, number and period as binaries" do
    claims = Guardian.Claims.app_claims
    |> Guardian.Claims.ttl({"5", "days"})

    {:ok, jwt, _} = Guardian.encode_and_sign("thinger", "my_type", claims)

    {:ok, claims} = Guardian.decode_and_verify(jwt)
    assert claims["exp"] == claims["iat"] + 5 * 24 * 60 * 60
  end

  test "encode_and_sign(object, aud) with exp and iat" do
    iat = Guardian.Utils.timestamp - 100
    exp = Guardian.Utils.timestamp + 100

    {:ok, jwt, _} = Guardian.encode_and_sign(
      "thinger",
      "my_type",
      %{"exp" => exp, "iat" => iat})

    {:ok, claims} = Guardian.decode_and_verify(jwt)
    assert claims["exp"] == exp
    assert claims["iat"] == iat
  end

  test "encode_and_sign with a serializer error" do
    {:error, reason} = Guardian.encode_and_sign(%{error: :unknown})
    assert reason
  end

  test "encode_and_sign calls before_encode_and_sign hook" do
    {:ok, _, _} = Guardian.encode_and_sign("before_encode_and_sign", "send")
    assert_received :before_encode_and_sign
  end

  test "encode_and_sign calls before_encode_and_sign hook w/ error" do
    {:error, reason} = Guardian.encode_and_sign("before_encode_and_sign", "error")
    assert reason == "before_encode_and_sign_error"
  end

  test "encode_and_sign calls after_encode_and_sign hook" do
    {:ok, _, _} = Guardian.encode_and_sign("after_encode_and_sign", "send")
    assert_received :after_encode_and_sign
  end

  test "encode_and_sign calls after_encode_and_sign hook w/ error" do
    {:error, reason} = Guardian.encode_and_sign("after_encode_and_sign", "error")
    assert reason == "after_encode_and_sign_error"
  end

  test "encode_and_sign with custom secret" do
    secret = "ABCDEF"
    {:ok, jwt, _} = Guardian.encode_and_sign(
      "thinger",
      "my_type",
      some: "thing",
      secret: secret
    )

    {:error, :invalid_token} = Guardian.decode_and_verify(jwt)
    {:ok, _claims} = Guardian.decode_and_verify(jwt, %{secret: secret})
  end

  test "encode_and_sign custom headers and custom secret %JOSE.JWK{} struct", context do
    secret = context.es512.jwk
    {:ok, jwt, _} = Guardian.encode_and_sign(
      "thinger",
      "my_type",
      headers: %{"alg" => "ES512"},
      some: "thing",
      secret: secret
    )

    {:error, :invalid_token} = Guardian.decode_and_verify(jwt)
    {:ok, _claims} = Guardian.decode_and_verify(jwt, %{secret: secret})
  end

  test "encode_and_sign custom headers and custom secret function without args" do
    secret = {Guardian.TestHelper, :secret_key_function}
    {:ok, jwt, _} = Guardian.encode_and_sign(
      "thinger",
      "my_type",
      some: "thing",
      secret: secret
    )

    {:error, :invalid_token} = Guardian.decode_and_verify(jwt)
    {:ok, _claims} = Guardian.decode_and_verify(jwt, %{secret: secret})
  end

  test "encode_and_sign custom headers and custom secret function with args", context do
    secret = {Guardian.TestHelper, :secret_key_function, [context.es512.jwk]}
    {:ok, jwt, _} = Guardian.encode_and_sign(
      "thinger",
      "my_type",
      headers: %{"alg" => "ES512"},
      some: "thing",
      secret: secret
    )

    {:error, :invalid_token} = Guardian.decode_and_verify(jwt)
    {:ok, _claims} = Guardian.decode_and_verify(jwt, %{secret: secret})
  end

  test "encode_and_sign custom headers and custom secret map", context do
    secret = context.es512.jwk |> JOSE.JWK.to_map |> elem(1)
    {:ok, jwt, _} = Guardian.encode_and_sign(
      "thinger",
      "my_type",
      headers: %{"alg" => "ES512"},
      some: "thing",
      secret: secret
    )

    {:error, :invalid_token} = Guardian.decode_and_verify(jwt)
    {:ok, _claims} = Guardian.decode_and_verify(jwt, %{secret: secret})
  end

  test "peeking at the headers" do
    secret = "ABCDEF"
    {:ok, jwt, _} = Guardian.encode_and_sign(
      "thinger",
      "my_type",
      some: "thing",
      secret: secret,
      headers: %{"foo" => "bar"}
    )

    header = Guardian.peek_header(jwt)
    assert header["foo"] == "bar"
  end

  test "peeking at the payload" do
    secret = "ABCDEF"
    {:ok, jwt, _} = Guardian.encode_and_sign(
      "thinger",
      "my_type",
      some: "thing",
      secret: secret,
      headers: %{"foo" => "bar"}
    )

    header = Guardian.peek_claims(jwt)
    assert header["some"] == "thing"
  end

  test "revoke" do
    {:ok, jwt, claims} = Guardian.encode_and_sign(
      "thinger",
      "my_type",
      some: "thing"
    )

    assert Guardian.revoke!(jwt, claims) == :ok
  end

  test "refresh" do

    old_claims = Guardian.Claims.app_claims
                 |> Map.put("iat", Guardian.Utils.timestamp - 100)
                 |> Map.put("exp", Guardian.Utils.timestamp + 100)

    {:ok, jwt, claims} = Guardian.encode_and_sign(
      "thinger",
      "my_type",
      old_claims
    )

    {:ok, new_jwt, new_claims} = Guardian.refresh!(jwt, claims)

    refute jwt == new_jwt

    refute Map.get(new_claims, "jti") == nil
    refute Map.get(new_claims, "jti") == Map.get(claims, "jti")

    refute Map.get(new_claims, "iat") == nil
    refute Map.get(new_claims, "iat") == Map.get(claims, "iat")

    refute Map.get(new_claims, "exp") == nil
    refute Map.get(new_claims, "exp") == Map.get(claims, "exp")
  end

  test "exchange" do
      {:ok, jwt, claims} = Guardian.encode_and_sign("thinger", "refresh")

      {:ok, new_jwt, new_claims} = Guardian.exchange(jwt, "refresh", "access")

      refute jwt == new_jwt
      refute Map.get(new_claims, "jti") == nil
      refute Map.get(new_claims, "jti") == Map.get(claims, "jti")

      refute Map.get(new_claims, "exp") == nil
      refute Map.get(new_claims, "exp") == Map.get(claims, "exp")
      assert Map.get(new_claims, "typ") == "access"
    end

    test "exchange with claims" do
      {:ok, jwt, claims} = Guardian.encode_and_sign("thinger", "refresh", some: "thing")

      {:ok, new_jwt, new_claims} = Guardian.exchange(jwt, "refresh", "access")

      refute jwt == new_jwt
      refute Map.get(new_claims, "jti") == nil
      refute Map.get(new_claims, "jti") == Map.get(claims, "jti")

      refute Map.get(new_claims, "exp") == nil
      refute Map.get(new_claims, "exp") == Map.get(claims, "exp")
      assert Map.get(new_claims, "typ") == "access"
      assert Map.get(new_claims, "some") == "thing"
    end

    test "exchange with list of from typs" do
      {:ok, jwt, claims} = Guardian.encode_and_sign("thinger", "rememberMe")

      {:ok, new_jwt, new_claims} = Guardian.exchange(jwt, ["refresh", "rememberMe"], "access")

      refute jwt == new_jwt
      refute Map.get(new_claims, "jti") == nil
      refute Map.get(new_claims, "jti") == Map.get(claims, "jti")

      refute Map.get(new_claims, "exp") == nil
      refute Map.get(new_claims, "exp") == Map.get(claims, "exp")
      assert Map.get(new_claims, "typ") == "access"
    end

    test "exchange with atom typ" do
      {:ok, jwt, claims} = Guardian.encode_and_sign("thinger", "refresh")

      {:ok, new_jwt, new_claims} = Guardian.exchange(jwt, :refresh, :access)

      refute jwt == new_jwt
      refute Map.get(new_claims, "jti") == nil
      refute Map.get(new_claims, "jti") == Map.get(claims, "jti")

      refute Map.get(new_claims, "exp") == nil
      refute Map.get(new_claims, "exp") == Map.get(claims, "exp")
      assert Map.get(new_claims, "typ") == "access"
    end

    test "exchange with a wrong from typ" do
      {:ok, jwt, _claims} = Guardian.encode_and_sign("thinger")
      assert  Guardian.exchange(jwt, "refresh", "access") == {:error, :incorrect_token_type}
  end

end
