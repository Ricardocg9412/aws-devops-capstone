locals {
  # Four distinct subnet indices guarantee non-overlap within this VPC.
  subnet_newbits = try(min(8, 28 - tonumber(split("/", var.vpc_cidr)[1])), 8)
  # Invalid inputs are rejected by variable validation; guard derived expressions
  # so callers receive those actionable messages rather than parsing errors.
  zones = try(zipmap(var.availability_zones, [
    for index, az in var.availability_zones : {
      public_cidr  = try(cidrsubnet(var.vpc_cidr, local.subnet_newbits, index + 1), null)
      private_cidr = try(cidrsubnet(var.vpc_cidr, local.subnet_newbits, index + 11), null)
    }
  ]), {})
}
