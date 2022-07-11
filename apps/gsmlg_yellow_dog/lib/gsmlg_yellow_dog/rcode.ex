defmodule GSMLGYellowDog.RCode do
  @moduledoc """
  GSMLGYellowDog.RCode set dns response code

  DNS Return Code	DNS Return Message	Description

  | RCODE:0	| NOERROR	| DNS Query completed successfully
  | RCODE:1	| FORMERR	| DNS Query Format Error
  | RCODE:2	| SERVFAIL	| Server failed to complete the DNS request
  | RCODE:3	| NXDOMAIN	| Domain name does not exist
  | RCODE:4	| NOTIMP	| Function not implemented
  | RCODE:5	| REFUSED	| The server refused to answer for the query
  | RCODE:6	| YXDOMAIN	| Name that should not exist, does exist
  | RCODE:7	| XRRSET	| RRset that should not exist, does exist
  | RCODE:8	| NOTAUTH	| Server not authoritative for the zone
  | RCODE:9	| NOTZONE	| Name not in zone
  """

  def to_code(name) do
    case name do
      :noerror -> 0
      :formerr -> 1
      :servfail -> 2
      :nxdomain -> 3
      :notimp -> 4
      :refused -> 5
      :yxdomain -> 6
      :xrrset -> 7
      :notauth -> 8
      :notzone -> 9
    end
  end
end
