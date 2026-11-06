"""v4 nodes: names, link encoding, selection and shared-rule deletion."""
from test_v4 import Sandbox


class NodeNamesTests(Sandbox):
    def test_rename_no_config_or_service_change(self):
        self.shell(r'''
before=$(sha256sum "$CONFIG_FILE")
rename_node node1 <<< $'香港 #1 & B\ny\n'
[ "$(node_display_name node1)" = '香港 #1 & B' ]
[ "$(sha256sum "$CONFIG_FILE")" = "$before" ]
[ ! -e "$ROOT/restarted" ]
[ "$(stat -c %a "$STATE_FILE")" = 600 ]
[[ "$(node_link node1)" == *'#%E9%A6%99%E6%B8%AF%20%231%20%26%20B' ]]
''')

    def test_name_invalid_and_eof(self):
        self.shell(r'''
if read_node_name <<< "$(printf '%081d' 0)"; then exit 1; fi
if read_node_name <<< $'bad\tname'; then exit 1; fi
if read_node_name < /dev/null; then exit 1; fi
''')

    def test_argo_link_uses_443_and_uri_path(self):
        self.shell(r'''
write_json "$CONFIG_FILE" '{"inbounds":[{"tag":"a","type":"vless","listen":"127.0.0.1","listen_port":21871,"users":[{"uuid":"uuid"}],"transport":{"type":"ws","path":"/my/path"}}],"route":{"rules":[]}}'
write_json "$STATE_FILE" '{"format":4,"nodes":{"a":{"kind":"argo","domain":"argo.example.com","name":"香港 #1"}}}'
link=$(node_link a)
[[ "$link" == vless://uuid@argo.example.com:443* ]]
[[ "$link" == *'host=argo.example.com&path=%2Fmy%2Fpath'* ]]
[[ "$link" != *21871* ]]
''')

    def test_delete_preserves_shared_rule_and_removes_empty(self):
        self.shell(r'''
write_json "$CONFIG_FILE" '{"inbounds":[{"tag":"node1"},{"tag":"node2"}],"route":{"rules":[{"inbound":["node1","node2"],"outbound":"warp"},{"inbound":["node1"],"outbound":"direct"},{"domain_suffix":["example.com"],"outbound":"warp"}]}}'
config_without_inbound node1 | jq -e '.inbounds[0].tag=="node2" and (.route.rules|length)==2 and .route.rules[0].inbound==["node2"] and .route.rules[1].domain_suffix==["example.com"]'
''')

    def test_rename_cancel_preserves_state(self):
        self.shell(r'''
before=$(sha256sum "$STATE_FILE")
if rename_node node1 <<< $'changed\nn\n'; then exit 1; fi
[ "$(sha256sum "$STATE_FILE")" = "$before" ]
''')
