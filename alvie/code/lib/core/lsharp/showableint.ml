open! Core

module ShowableInt = struct
  include Int [@@deriving show]
  let show = [%derive.show: int]

  let default = 0
end
