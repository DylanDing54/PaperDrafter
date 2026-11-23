from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Resources"))
from location import locate

class SectionLocationTest(unittest.TestCase):
    def test_nested_input_with_unsaved_edits_and_utf16_offset(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            main, child, leaf = [root / name for name in ["main.tex","child.tex","leaf.tex"]]
            main.write_text(r"\section{Evaluation}\input{child}")
            child.write_text(r"\subsection{Timing}\include{leaf}")
            leaf.write_text("Outdated disk text.")
            prefix = "% \\section{Wrong section}\n第一段😀。\n\nA first sentence. "
            selected = "We measured latency."
            request = {"source":prefix + selected + " Another sentence.\n",
                       "text":selected, "offset":len(prefix.encode("utf-16-le"))//2,
                       "root":directory,"file":str(leaf),"main":str(main)}
            pos = locate(request)
            self.assertEqual(pos["headings"], ["Evaluation","Timing"])
            self.assertEqual((pos["role"],pos["paragraph"],pos["placement"]),("evaluation",2,"middle"))
            main.write_text(r"\begin{abstract}\input{child}\end{abstract}")
            self.assertEqual(locate(request)["role"],"abstract")

    def test_primary_section_determines_corpus_bucket(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "main.tex"
            before = r"\section{Introduction}\subsection{Experimental results}"
            pos = locate({"text":"Sample","offset":len(before),"source":before+"Sample",
                          "root":directory,"main":str(file),"file":str(file)})
            self.assertEqual(pos["role"], "introduction")

if __name__ == "__main__":
    unittest.main()
