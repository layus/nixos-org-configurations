{ config, pkgs, ... }:

with pkgs.lib;

let 

  machines = import ./machines.nix;

  # Produce the list of Nix build machines in the format expected by
  # the Nix daemon Upstart job.
  buildMachines =
    let addKey = machine: machine // 
      { sshKey = "/root/.ssh/id_buildfarm";
        sshUser = machine.buildUser;
      };
    in map addKey (filter (machine: machine ? buildUser) machines);

  jiraJetty = (import ../../services/jira/jira-instance.nix).jetty;

  myIP = "130.161.158.181";

  releasesCSS = /etc/nixos/release/generic-dist/release-page/releases.css;

  ZabbixApacheUpdater = pkgs.fetchsvn {
    url = https://www.zulukilo.com/svn/pub/zabbix-apache-stats/trunk/fetch.py;
    sha256 = "1q66x429wpqjqcmlsi3x37rkn95i55nj8ldzcrblnx6a0jnjgd2g";
    rev = 94;
  };

in

rec {
  require = [ ./common.nix ];

  boot = {
    loader.grub.device = "/dev/sda";
    loader.grub.copyKernels = true;
    initrd.kernelModules = ["arcmsr"];
    kernelModules = ["kvm-intel"];
  };

  fileSystems = [
    { mountPoint = "/";
      label = "nixos";
      options = "acl";
    }
  ];

  swapDevices = [
    { label = "swap1"; }
  ];
  
  nix = {
    maxJobs = 2;
    distributedBuilds = true;
    inherit buildMachines;
    extraOptions = ''
      gc-keep-outputs = true
    '';
  };
  
  networking = {
    hostName = "cartman";
    domain = "buildfarm";

    interfaces = [
      { name = "eth1";
        ipAddress = myIP;
        subnetMask = "255.255.254.0";
      }
      { name = "eth0";
        ipAddress = (findSingle (m: m.hostName == "cartman") {} {} machines).ipAddress;
      }
    ];

    defaultGateway = "130.161.158.1";

    nameservers = ["130.161.158.4" "130.161.33.17" "130.161.180.1"];

    extraHosts = 
      let toHosts = m: "${m.ipAddress} ${m.hostName} ${concatStringsSep " " (if m ? aliases then m.aliases else [])}\n"; in
      concatStrings (map toHosts machines);

    localCommands =
      # Provide NATting for the build machines on 192.168.1.*.
      # Obviously, this should be something that NixOS provides.
      ''
        export PATH=${pkgs.iptables}/sbin:$PATH

        modprobe ip_tables
        modprobe ip_conntrack_ftp
        modprobe ip_nat_ftp
        modprobe ipt_LOG
        modprobe ip_nat
        modprobe xt_tcpudp

        iptables -t nat -F
        iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -d 192.168.1.0/24 -j ACCEPT
        iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -j SNAT --to-source ${myIP}

        # losser ssh
        iptables -t nat -A PREROUTING -p tcp -i eth1 --dport 8080 -j DNAT --to 192.168.1.18:2022

        echo 1 > /proc/sys/net/ipv4/ip_forward
      '';

    defaultMailServer = {
      directDelivery = true;
      hostName = "smtp.st.ewi.tudelft.nl";
      domain = "st.ewi.tudelft.nl";
    };
  };

  services = {
    cron = {
      mailto = "rob.vermaas@gmail.com";
      systemCronJobs =
        let indexJob = hour: dir: url: 
          "45 ${toString hour} * * *  buildfarm  (cd /etc/nixos/release/index && PATH=${pkgs.saxonb}/bin:$PATH ./make-index.sh ${dir} ${url} /releases.css) | ${pkgs.utillinux}/bin/logger -t index";
        in
        [
          "15 0 * * *  root  (TZ=CET date; ${pkgs.rsync}/bin/rsync -razv --numeric-ids --delete /data/postgresql /data/webserver/tarballs unixhome.st.ewi.tudelft.nl::bfarm/) >> /var/log/backup.log 2>&1"
          (indexJob 02 "/data/webserver/dist/strategoxt2" http://releases.strategoxt.org/)
          (indexJob 05 "/data/webserver/dist" http://buildfarm.st.ewi.tudelft.nl/)

          "00 03 * * * root ${pkgs.nixUnstable}/bin/nix-collect-garbage --max-atime $(date +\\%s -d '2 weeks ago') > /var/log/gc.log 2>&1"
          "*  *  * * * root ${pkgs.python}/bin/python ${ZabbixApacheUpdater} -z 192.168.1.5 -c cartman"
        ];
    };

    dhcpd = {
      enable = true;
      interfaces = ["eth0"];
      extraConfig = ''
        option subnet-mask 255.255.255.0;
        option broadcast-address 192.168.1.255;
        option routers 192.168.1.5;
        option domain-name-servers 130.161.158.4, 130.161.33.17, 130.161.180.1;
        option domain-name "buildfarm-net";

        subnet 192.168.1.0 netmask 255.255.255.0 {
          range 192.168.1.100 192.168.1.200;
        }

        use-host-decl-names on;
      '';
      machines = filter (machine: machine ? ethernetAddress) machines;
    };
    
    postgresql = {
      enable = true;
      enableTCPIP = true;
      dataDir = "/data/postgresql";
      authentication = ''
          local all mediawiki        ident mediawiki-users
          local all all              ident sameuser
          host  all all 127.0.0.1/32 md5
          host  all all ::1/128      md5
          host  all all 192.168.1.18/32  md5
          host  all all 130.161.159.80/32 md5
          host  all all 94.208.32.143/32 md5
        '';
    };

    httpd = {
      enable = true;
      logPerVirtualHost = true;
      adminAddr = "e.dolstra@tudelft.nl";
      hostName = "localhost";

      sslServerCert = "/root/ssl-secrets/server.crt";
      sslServerKey = "/root/ssl-secrets/server.key";
          
      extraConfig = ''
        AddType application/nix-package .nixpkg

        SSLProtocol all -TLSv1

        <Location /server-status>
                SetHandler server-status
                Allow from 127.0.0.1 # If using a remote host for monitoring replace 127.0.0.1 with its IP. 
                Order deny,allow
                Deny from all
        </Location>
        ExtendedStatus On
      '';
          
      servedFiles = [
        { urlPath = "/releases.css";
          file = releasesCSS;
        }
        { urlPath = "/css/releases.css"; # legacy; old releases point here
          file = releasesCSS;
        }
        { urlPath = "/releases/css/releases.css"; # legacy; old releases point here
          file = releasesCSS;
        }
      ];
      
      virtualHosts = [

        { hostName = "buildfarm.st.ewi.tudelft.nl";
          documentRoot = cleanSource ./webroot;
          enableUserDir = true;
          extraSubservices = [
            { serviceType = "subversion";
              urlPrefix = "";
              toplevelRedirect = false;
              dataDir = "/data/subversion";
              notificationSender = "svn@buildfarm.st.ewi.tudelft.nl";
              userCreationDomain = "st.ewi.tudelft.nl";
              organisation = {
                name = "Software Engineering Research Group, TU Delft";
                url = http://www.st.ewi.tudelft.nl/;
                logo = "/serg-logo.png";
              };
            }
            { serviceType = "subversion";
              id = "ptg";
              urlPrefix = "/ptg";
              dataDir = "/data/subversion-ptg";
              notificationSender = "svn@buildfarm.st.ewi.tudelft.nl";
              userCreationDomain = "st.ewi.tudelft.nl";
              organisation = {
                name = "Software Engineering Research Group, TU Delft";
                url = http://www.st.ewi.tudelft.nl/;
                logo = "/serg-logo.png";
              };
            }
            { serviceType = "zabbix";
              urlPrefix = "/zabbix";
            }
          ];
          servedDirs = [
            { urlPath = "/releases";
              dir = "/data/webserver/dist";
            }
          ];
        }

        # Default vhost for SSL; nothing here yet, but we need it,
        # otherwise SSL requests that don't match with any vhost will
        # go to svn.strategoxt.org.
        { hostName = "buildfarm.st.ewi.tudelft.nl";
          enableSSL = true;
          globalRedirect = "http://buildfarm.st.ewi.tudelft.nl/";
        }
        
        { hostName = "strategoxt.org";
          extraSubservices = [
            { serviceType = "twiki";
              startWeb = "Stratego/WebHome";
              dataDir = "/data/pt-wiki/data";
              pubDir = "/data/pt-wiki/pub";
              twikiName = "Stratego/XT Wiki";
              registrationDomain = "ewi.tudelft.nl";
            }
          ];
        }

        { hostName = "www.strategoxt.org";
          serverAliases = ["www.stratego-language.org"];
          globalRedirect = "http://strategoxt.org/";
        }

        { hostName = "svn.strategoxt.org";
          globalRedirect = "https://svn.strategoxt.org/";
        }
        
        { hostName = "svn.strategoxt.org";
          enableSSL = true;
          extraSubservices = [
            { serviceType = "subversion";
              id = "strategoxt";
              urlPrefix = "";
              dataDir = "/data/subversion-strategoxt";
              notificationSender = "svn@svn.strategoxt.org";
              userCreationDomain = "st.ewi.tudelft.nl";
              organisation = {
                name = "Stratego/XT";
                url = http://strategoxt.org/;
                logo = http://strategoxt.org/pub/Stratego/StrategoLogo/StrategoLogoTextlessWhite-100px.png;
              };
            }
          ];
        }

        { hostName = "program-transformation.org";
          serverAliases = ["www.program-transformation.org"];
          extraSubservices = [
            { serviceType = "twiki";
              startWeb = "Transform/WebHome";
              dataDir = "/data/pt-wiki/data";
              pubDir = "/data/pt-wiki/pub";
              twikiName = "Program Transformation Wiki";
              registrationDomain = "ewi.tudelft.nl";
            }
          ];
        }

        { hostName = "bugs.strategoxt.org";
          extraConfig = ''
            <Proxy *>
              Order deny,allow
              Allow from all
            </Proxy>

            ProxyRequests     Off
            ProxyPreserveHost On
            ProxyPass         /       http://localhost:10080/
            ProxyPassReverse  /       http://localhost:10080/
          '';
        }

        { hostName = "releases.strategoxt.org";
          documentRoot = "/data/webserver/dist/strategoxt2";
        }

        { hostName = "nixos.org";
          documentRoot = "/home/eelco/nix-homepage";
          servedDirs = [
            { urlPath = "/releases";
              dir = "/data/webserver/dist/nix";
            }
            { urlPath = "/tarballs";
              dir = "/data/webserver/tarballs";
            }
            { urlPath = "/irc";
              dir = "/data/webserver/irc";
            }
          ];
          servedFiles = [
            { urlPath = "/releases/css/releases.css";
              file = releasesCSS;
            }
          ];
        }

        { hostName = "www.nixos.org";
          globalRedirect = "http://nixos.org/";
        }
        
        { hostName = "svn.nixos.org";
          enableSSL = true;
          extraSubservices = [
            { serviceType = "subversion";
              id = "nix";
              urlPrefix = "";
              dataDir = "/data/subversion-nix";
              notificationSender = "svn@svn.nixos.org";
              userCreationDomain = "st.ewi.tudelft.nl";
              organisation = {
                name = "Nix";
                url = http://nixos.org/;
                logo = http://nixos.org/logo/nixos-lores.png;
              };
            }
          ];
        }

        { hostName = "svn.nixos.org";
          globalRedirect = "https://svn.nixos.org/";
        }
        
        { hostName = "hydra.nixos.org";
          extraConfig = ''
            <Proxy *>
              Order deny,allow
              Allow from all
            </Proxy>

            ProxyRequests     Off
            ProxyPreserveHost On
            ProxyPass         /       http://hydra:3000/ retry=5
            ProxyPassReverse  /       http://hydra:3000/
          '';
        }

        { hostName = "wiki.nixos.org";
          extraConfig = ''
            RedirectMatch ^/$ /wiki
          '';
          extraSubservices = [
            { serviceType = "mediawiki";
              siteName = "Nix Wiki";
              logo = "http://nixos.org/logo/nix-wiki.png";
              extraConfig =
                ''
                  $wgEmailConfirmToEdit = true;
                '';
            }
          ];
        }

        { hostName = "planet.strategoxt.org";
          serverAliases = ["planet.stratego.org"];
          documentRoot = "/home/karltk/public_html/planet";
        }

        { hostName = "test.researchr.org";
          extraConfig = ''
            <Proxy *>
              Order deny,allow
              Allow from all
            </Proxy>

            ProxyRequests     Off
            ProxyPreserveHost On
            ProxyPass         /       http://mrhankey:8080/ retry=5
            ProxyPassReverse  /       http://mrhankey:8080/
          '';
        }

        { hostName = "test.nixos.org";
          extraConfig = ''
            <Proxy *>
              Order deny,allow
              Allow from all
            </Proxy>

            ProxyRequests     Off
            ProxyPreserveHost On
            ProxyPass         /       http://mrhankey:8080/ retry=5
            ProxyPassReverse  /       http://mrhankey:8080/
          '';
        }

      ];
    };

    postgresqlBackup = {
      enable = true;
      databases = [ "jira" ];
    };

    sitecopy = {
      enable = true;
      backups =
        let genericBackup = { server = "webdata.tudelft.nl";
                              protocol = "webdav";
                              https = true ;
                              symlinks = "ignore"; 
                            };
        in [
          ( genericBackup // { name   = "postgresql";
                               local  = config.services.postgresqlBackup.location;
                               remote = "/staff-groups/ewi/st/strategoxt/backup/postgresql"; 
                             } )
          ( genericBackup // { name   = "subversion";
                               local  = "/data/subversion";
                               remote = "/staff-groups/ewi/st/strategoxt/backup/subversion/subversion"; 
                             } )
          ( genericBackup // { name   = "subversion-nix";
                               local  = "/data/subversion-nix";
                               remote = "/staff-groups/ewi/st/strategoxt/backup/subversion/subversion-nix"; 
                               period = "15 03 * * *"; 
                             } )
          ( genericBackup // { name   = "subversion-ptg";
                               local  = "/data/subversion-ptg";
                               remote = "/staff-groups/ewi/st/strategoxt/backup/subversion/subversion-ptg"; 
                             } )
          ( genericBackup // { name   = "subversion-strategoxt"; 
                               local  = "/data/subversion-strategoxt";
                               remote = "/staff-groups/ewi/st/strategoxt/backup/subversion/subversion-strategoxt"; 
                               period = "15 02 * * *"; 
                             } )
          ( genericBackup // { name   = "webserver-dist-nix"; 
                               local  = "/data/webserver/dist/nix";
                               remote = "/staff-groups/ewi/st/strategoxt/backup/webserver-dist-nix"; 
                               period = "5 03 * * *"; 
                             } )
#          ( genericBackup // { name   = "webserver-tarballs"; 
#                               local  = "/data/webserver/tarballs";
#                               remote = "/staff-groups/ewi/st/strategoxt/backup/webserver-tarballs"; 
#                               period = "5 03 * * *"; 
#                             } )
          ( genericBackup // { name   = "pt-wiki"; 
                               local  = "/data/pt-wiki";
                               remote = "/staff-groups/ewi/st/strategoxt/backup/pt-wiki"; 
                               period = "55 02 * * *"; 
                             } )
        ];
      };

    zabbixAgent.enable = true;
    
    zabbixServer.enable = true;

  };

  users.extraUsers = singleton
    { name = "jira";
      description = "JIRA bug tracker";
    };

  jobs.jira =
    { description = "JIRA bug tracker";

      startOn = "started network-interfaces";

      preStart =
        ''
          mkdir -p /var/log/jetty /var/cache/jira
          chown jira /var/log/jetty /var/cache/jira
        '';

      exec = "${pkgs.su}/bin/su -s ${pkgs.bash}/bin/sh jira -c '${jiraJetty}/bin/run-jetty'";

      postStop =
        ''
          ${pkgs.su}/bin/su -s ${pkgs.bash}/bin/sh jira -c '${jiraJetty}/bin/stop-jetty'
        '';
    };

}
