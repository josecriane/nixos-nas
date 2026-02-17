{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.nas.reverseProxy;
in
{
  options.nas.reverseProxy = {
    enable = mkEnableOption "Nginx reverse proxy for web services";

    domain = mkOption {
      type = types.str;
      default = "nas.local";
      description = "Base domain for the NAS services";
    };

    ssl = {
      enable = mkEnableOption "Enable SSL/TLS";
      useSelfSigned = mkOption {
        type = types.bool;
        default = true;
        description = "Use self-signed certificates (disable for Let's Encrypt)";
      };
      certificatePath = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Path to SSL certificate (if not using self-signed)";
      };
      keyPath = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Path to SSL private key (if not using self-signed)";
      };
    };

    authentik = {
      enable = mkEnableOption "Authentik integration";
      url = mkOption {
        type = types.str;
        default = "https://authentik.local";
        description = "Authentik server URL";
      };
      outpostUrl = mkOption {
        type = types.str;
        default = "http://authentik-outpost:9000";
        description = "Authentik outpost URL for forward auth";
      };
    };

    cockpit = {
      enable = mkOption {
        type = types.bool;
        default = config.nas.webui.cockpit.enable or false;
        description = "Enable reverse proxy for Cockpit";
      };
      subdomain = mkOption {
        type = types.str;
        default = "cockpit";
        description = "Subdomain for Cockpit";
      };
    };

    filebrowser = {
      enable = mkOption {
        type = types.bool;
        default = config.nas.webui.filebrowser.enable or false;
        description = "Enable reverse proxy for File Browser";
      };
      subdomain = mkOption {
        type = types.str;
        default = "files";
        description = "Subdomain for File Browser";
      };
    };
  };

  config = mkIf cfg.enable {
    services.nginx = {
      enable = true;

      appendHttpConfig = ''
        worker_processes auto;
        worker_rlimit_nofile 8192;

        events {
          worker_connections 1024;
          use epoll;
        }

        client_body_buffer_size 128k;
        client_max_body_size 10G;
        client_header_buffer_size 1k;
        large_client_header_buffers 4 8k;

        client_body_timeout 60s;
        client_header_timeout 60s;
        keepalive_timeout 65s;
        send_timeout 60s;

        gzip on;
        gzip_vary on;
        gzip_proxied any;
        gzip_comp_level 6;
        gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss;

        server_tokens off;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
      '';

      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;

      virtualHosts =
        let
          sslConfig =
            if cfg.ssl.enable then
              {
                forceSSL = true;
                sslCertificate =
                  if cfg.ssl.useSelfSigned then "/var/lib/acme/${cfg.domain}/cert.pem" else cfg.ssl.certificatePath;
                sslCertificateKey =
                  if cfg.ssl.useSelfSigned then "/var/lib/acme/${cfg.domain}/key.pem" else cfg.ssl.keyPath;
              }
            else
              { };

          authentikConfig = optionalAttrs cfg.authentik.enable {
            locations."@forward-auth" = {
              extraConfig = ''
                internal;
                proxy_pass ${cfg.authentik.outpostUrl}/outpost.goauthentik.io/auth/nginx;
                proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_set_header X-Forwarded-Host $http_host;
                proxy_set_header X-Forwarded-Uri $request_uri;
                proxy_set_header X-Forwarded-For $remote_addr;
                proxy_pass_request_body off;
                proxy_set_header Content-Length "";
              '';
            };
          };
        in
        {
          "${cfg.cockpit.subdomain}.${cfg.domain}" = mkIf cfg.cockpit.enable (
            sslConfig
            // authentikConfig
            // {
              locations."/" = {
                proxyPass = "http://127.0.0.1:${toString config.nas.webui.cockpit.port}";
                proxyWebsockets = true;
                extraConfig = ''
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto $scheme;
                  proxy_set_header X-Forwarded-Host $host;

                  ${optionalString cfg.authentik.enable ''
                    auth_request @forward-auth;
                    auth_request_set $auth_user $upstream_http_x_authentik_username;
                    auth_request_set $auth_email $upstream_http_x_authentik_email;
                    proxy_set_header X-authentik-username $auth_user;
                    proxy_set_header X-authentik-email $auth_email;
                    proxy_set_header Remote-User $auth_user;
                    proxy_set_header Remote-Email $auth_email;
                  ''}

                  proxy_buffering off;
                  proxy_http_version 1.1;
                  proxy_set_header Upgrade $http_upgrade;
                  proxy_set_header Connection "upgrade";
                '';
              };
            }
          );

          "${cfg.filebrowser.subdomain}.${cfg.domain}" = mkIf cfg.filebrowser.enable (
            sslConfig
            // authentikConfig
            // {
              locations."/" = {
                proxyPass = "http://127.0.0.1:${toString config.nas.webui.filebrowser.port}";
                extraConfig = ''
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto $scheme;

                  ${optionalString cfg.authentik.enable ''
                    auth_request @forward-auth;
                    auth_request_set $auth_user $upstream_http_x_authentik_username;
                    auth_request_set $auth_email $upstream_http_x_authentik_email;
                    proxy_set_header X-authentik-username $auth_user;
                    proxy_set_header X-authentik-email $auth_email;
                  ''}

                  client_max_body_size 10G;
                  proxy_request_buffering off;
                '';
              };
            }
          );

          "${cfg.domain}" = sslConfig // {
            locations."/" = {
              extraConfig = ''
                return 200 '
                <!DOCTYPE html>
                <html>
                <head>
                  <title>NixOS NAS</title>
                  <meta charset="UTF-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1.0">
                  <style>
                    body {
                      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                      max-width: 800px;
                      margin: 50px auto;
                      padding: 20px;
                      background: #f5f5f5;
                    }
                    h1 { color: #333; }
                    .services {
                      display: grid;
                      grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
                      gap: 20px;
                      margin-top: 30px;
                    }
                    .service {
                      background: white;
                      padding: 20px;
                      border-radius: 8px;
                      box-shadow: 0 2px 4px rgba(0,0,0,0.1);
                      text-decoration: none;
                      color: inherit;
                      transition: transform 0.2s;
                    }
                    .service:hover {
                      transform: translateY(-2px);
                      box-shadow: 0 4px 8px rgba(0,0,0,0.15);
                    }
                    .service h2 {
                      margin-top: 0;
                      color: #5294e2;
                    }
                  </style>
                </head>
                <body>
                  <h1>NixOS NAS Dashboard</h1>
                  <p>Storage system with MergerFS and SnapRAID</p>
                  <div class="services">
                    ${optionalString cfg.cockpit.enable ''
                      <a href="https://${cfg.cockpit.subdomain}.${cfg.domain}" class="service">
                        <h2>Cockpit</h2>
                        <p>System administration</p>
                      </a>
                    ''}
                    ${optionalString cfg.filebrowser.enable ''
                      <a href="https://${cfg.filebrowser.subdomain}.${cfg.domain}" class="service">
                        <h2>File Browser</h2>
                        <p>Web file manager</p>
                      </a>
                    ''}
                  </div>
                </body>
                </html>
                ';
                add_header Content-Type text/html;
              '';
            };
          };
        };
    };

    security.acme = mkIf (cfg.ssl.enable && cfg.ssl.useSelfSigned) {
      acceptTerms = true;
      defaults.email = "admin@${cfg.domain}";

      certs."${cfg.domain}" = {
        domain = "*.${cfg.domain}";
        extraDomainNames = [ cfg.domain ];
      };
    };

    networking.firewall.allowedTCPPorts = [ 80 ] ++ optional cfg.ssl.enable 443;

    environment.systemPackages = [ pkgs.nginx ];
  };
}
