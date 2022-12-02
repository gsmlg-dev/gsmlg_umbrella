# support whois type:
#   asn16.json
# 	asn32.json
#		ipv4.json
#		ipv6.json
#		tld.json
default: tld.csv ipv6.csv ipv4.csv asn32.csv asn16.csv

asn16.json:
	curl -s -L https://github.com/weppos/whois/raw/main/data/asn16.json > asn16.json

asn16.csv: asn16.json
	cat asn16.json | jq -r 'to_entries | .[] | select(.value.host) | .key + "," + .value.host' > asn16.csv

asn32.json:
	curl -s -L https://github.com/weppos/whois/raw/main/data/asn32.json > asn32.json

asn32.csv: asn32.json
	cat asn32.json | jq -r 'to_entries | .[] | select(.value.host) | .key + "," + .value.host' > asn32.csv

ipv4.json:
	curl -s -L https://github.com/weppos/whois/raw/main/data/ipv4.json > ipv4.json

ipv4.csv: ipv4.json
	cat ipv4.json | jq -r 'to_entries | .[] | select(.value.host) | .key + "," + .value.host' > ipv4.csv

ipv6.json:
	curl -s -L https://github.com/weppos/whois/raw/main/data/ipv6.json > ipv6.json

ipv6.csv: ipv6.json
	cat ipv6.json | jq -r 'to_entries | .[] | select(.value.host) | .key + "," + .value.host' > ipv6.csv

tld.json:
	curl -s -L https://github.com/weppos/whois/raw/main/data/tld.json > tld.json

tld.csv: tld.json
	cat tld.json | jq -r 'to_entries | .[] | select(.value.host) | .key + "," + .value.host' > tld.csv

clean:
	rm -f tld.json tld.csv
