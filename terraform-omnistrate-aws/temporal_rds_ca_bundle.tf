# AWS RDS regional root CA, PINNED — the trust anchor for verify-full on every
# Temporal SQL client (bootstrap psql, temporal-sql-tool, server datastores) via
# the temporal-rds-ca ConfigMap. Only the root for the instance's
# ca_cert_identifier (rds-ca-rsa2048-g1, set explicitly on
# aws_db_instance.temporal) is pinned, one per supported region; the two must
# change together. Valid until 2061; RDS server-cert rotation stays under it.
#
# Embedded as a .tf string literal, deliberately:
#   - Omnistrate's git ingestion materializes ONLY .tf files onto the
#     tf-executor, so a repo data file (files/*.pem) is absent there and a
#     constant-arg file() breaks plan for EVERY cell at validate time, even
#     count-gated (live cell, 2026-08-10).
#   - A plan-time fetch would need tf-executor egress, which default-deny
#     cells restrict; a pinned, reviewed root is also the right posture for
#     regulated zero-egress customers — no trust anchor changing under us.
#
# New region: add its "Amazon RDS <region> Root CA RSA2048 G1" entry from
#   curl -s https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem
locals {
  rds_root_ca = {
    # Amazon RDS us-east-1 Root CA RSA2048 G1
    "us-east-1" = <<-PEM
      -----BEGIN CERTIFICATE-----
      MIID/zCCAuegAwIBAgIRAPVSMfFitmM5PhmbaOFoGfUwDQYJKoZIhvcNAQELBQAw
      gZcxCzAJBgNVBAYTAlVTMSIwIAYDVQQKDBlBbWF6b24gV2ViIFNlcnZpY2VzLCBJ
      bmMuMRMwEQYDVQQLDApBbWF6b24gUkRTMQswCQYDVQQIDAJXQTEwMC4GA1UEAwwn
      QW1hem9uIFJEUyB1cy1lYXN0LTEgUm9vdCBDQSBSU0EyMDQ4IEcxMRAwDgYDVQQH
      DAdTZWF0dGxlMCAXDTIxMDUyNTIyMzQ1N1oYDzIwNjEwNTI1MjMzNDU3WjCBlzEL
      MAkGA1UEBhMCVVMxIjAgBgNVBAoMGUFtYXpvbiBXZWIgU2VydmljZXMsIEluYy4x
      EzARBgNVBAsMCkFtYXpvbiBSRFMxCzAJBgNVBAgMAldBMTAwLgYDVQQDDCdBbWF6
      b24gUkRTIHVzLWVhc3QtMSBSb290IENBIFJTQTIwNDggRzExEDAOBgNVBAcMB1Nl
      YXR0bGUwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDu9H7TBeGoDzMr
      dxN6H8COntJX4IR6dbyhnj5qMD4xl/IWvp50lt0VpmMd+z2PNZzx8RazeGC5IniV
      5nrLg0AKWRQ2A/lGGXbUrGXCSe09brMQCxWBSIYe1WZZ1iU1IJ/6Bp4D2YEHpXrW
      bPkOq5x3YPcsoitgm1Xh8ygz6vb7PsvJvPbvRMnkDg5IqEThapPjmKb8ZJWyEFEE
      QRrkCIRueB1EqQtJw0fvP4PKDlCJAKBEs/y049FoOqYpT3pRy0WKqPhWve+hScMd
      6obq8kxTFy1IHACjHc51nrGII5Bt76/MpTWhnJIJrCnq1/Uc3Qs8IVeb+sLaFC8K
      DI69Sw6bAgMBAAGjQjBAMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFE7PCopt
      lyOgtXX0Y1lObBUxuKaCMA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsFAAOC
      AQEAFj+bX8gLmMNefr5jRJfHjrL3iuZCjf7YEZgn89pS4z8408mjj9z6Q5D1H7yS
      jNETVV8QaJip1qyhh5gRzRaArgGAYvi2/r0zPsy+Tgf7v1KGL5Lh8NT8iCEGGXwF
      g3Ir+Nl3e+9XUp0eyyzBIjHtjLBm6yy8rGk9p6OtFDQnKF5OxwbAgip42CD75r/q
      p421maEDDvvRFR4D+99JZxgAYDBGqRRceUoe16qDzbMvlz0A9paCZFclxeftAxv6
      QlR5rItMz/XdzpBJUpYhdzM0gCzAzdQuVO5tjJxmXhkSMcDP+8Q+Uv6FA9k2VpUV
      E/O5jgpqUJJ2Hc/5rs9VkAPXeA==
      -----END CERTIFICATE-----
    PEM
    # Amazon RDS us-east-2 Root CA RSA2048 G1
    "us-east-2" = <<-PEM
      -----BEGIN CERTIFICATE-----
      MIID/zCCAuegAwIBAgIRAJYlnmkGRj4ju/2jBQsnXJYwDQYJKoZIhvcNAQELBQAw
      gZcxCzAJBgNVBAYTAlVTMSIwIAYDVQQKDBlBbWF6b24gV2ViIFNlcnZpY2VzLCBJ
      bmMuMRMwEQYDVQQLDApBbWF6b24gUkRTMQswCQYDVQQIDAJXQTEwMC4GA1UEAwwn
      QW1hem9uIFJEUyB1cy1lYXN0LTIgUm9vdCBDQSBSU0EyMDQ4IEcxMRAwDgYDVQQH
      DAdTZWF0dGxlMCAXDTIxMDUyMTIzMDQ0NFoYDzIwNjEwNTIyMDAwNDQ0WjCBlzEL
      MAkGA1UEBhMCVVMxIjAgBgNVBAoMGUFtYXpvbiBXZWIgU2VydmljZXMsIEluYy4x
      EzARBgNVBAsMCkFtYXpvbiBSRFMxCzAJBgNVBAgMAldBMTAwLgYDVQQDDCdBbWF6
      b24gUkRTIHVzLWVhc3QtMiBSb290IENBIFJTQTIwNDggRzExEDAOBgNVBAcMB1Nl
      YXR0bGUwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC74V3eigv+pCj5
      nqDBqplY0Jp16pTeNB06IKbzb4MOTvNde6QjsZxrE1xUmprT8LxQqN9tI3aDYEYk
      b9v4F99WtQVgCv3Y34tYKX9NwWQgwS1vQwnIR8zOFBYqsAsHEkeJuSqAB12AYUSd
      Zv2RVFjiFmYJho2X30IrSLQfS/IE3KV7fCyMMm154+/K1Z2IJlcissydEAwgsUHw
      edrE6CxJVkkJ3EvIgG4ugK/suxd8eEMztaQYJwSdN8TdfT59LFuSPl7zmF3fIBdJ
      //WexcQmGabaJ7Xnx+6o2HTfkP8Zzzzaq8fvjAcvA7gyFH5EP26G2ZqMG+0y4pTx
      SPVTrQEXAgMBAAGjQjBAMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFIWWuNEF
      sUMOC82XlfJeqazzrkPDMA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsFAAOC
      AQEAgClmxcJaQTGpEZmjElL8G2Zc8lGc+ylGjiNlSIw8X25/bcLRptbDA90nuP+q
      zXAMhEf0ccbdpwxG/P5a8JipmHgqQLHfpkvaXx+0CuP++3k+chAJ3Gk5XtY587jX
      +MJfrPgjFt7vmMaKmynndf+NaIJAYczjhJj6xjPWmGrjM3MlTa9XesmelMwP3jep
      bApIWAvCYVjGndbK9byyMq1nyj0TUzB8oJZQooaR3MMjHTmADuVBylWzkRMxbKPl
      4Nlsk4Ef1JvIWBCzsMt+X17nuKfEatRfp3c9tbpGlAE/DSP0W2/Lnayxr4RpE9ds
      ICF35uSis/7ZlsftODUe8wtpkQ==
      -----END CERTIFICATE-----
    PEM
  }
}
