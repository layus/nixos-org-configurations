{
  #inputs.nixpkgs.url = "/home/deploy/src/edolstra-nixpkgs"; # toString ../../edolstra-nixpkgs; # = "nixpkgs/release-19.09";
  inputs.nixpkgs.url = "nixpkgs/nixos-20.03";

  outputs = flakes @ { self, nixpkgs, nix, hydra, dwarffs }: {

    nixopsConfigurations.default =
      { inherit nixpkgs; }
      // import ./network.nix flakes;

  };
}
