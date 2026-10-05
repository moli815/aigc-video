import sys,json
from pathlib import Path
from tree_sitter import Language,Parser,Query,QueryCursor
import tree_sitter_swift
language=Language(tree_sitter_swift.language())
parser=Parser(language)
tree=parser.parse(Path(sys.argv[1]).read_bytes())
details=[]
if tree.root_node.has_error:
    cursor=QueryCursor(Query(language,'(ERROR) @error (MISSING) @missing'))
    for kind,nodes in cursor.captures(tree.root_node).items():
        for node in nodes:
            details.append({'kind':kind,'line':node.start_point.row+1,'text':node.text.decode('utf8')[:120]})
print(json.dumps({'has_error':tree.root_node.has_error,'details':details}),flush=True)
