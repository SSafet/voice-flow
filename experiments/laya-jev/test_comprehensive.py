import unittest
import tempfile
from comprehensive import score, metrics, digest
from comprehensive_cases import core_cases, robustness_cases, image_cases, noul, case


class BenchmarkTests(unittest.TestCase):
    def test_image_controls_use_verified_flat_parts_without_answer_text(self):
        with tempfile.TemporaryDirectory() as directory:
            cs=image_cases(directory)
        controls=cs[:4]
        texts=[]
        for c in controls:
            self.assertEqual([p['type'] for p in c['state']],['text','image_url'])
            self.assertTrue(c['state'][1]['image_url']['url'].startswith('data:image/png;base64,'))
            texts.append(c['state'][0]['text'])
        self.assertEqual(len(set(texts)),1)
        self.assertEqual(len({c['state'][1]['image_url']['url'] for c in controls}),4)
        self.assertEqual(cs[-1]['expected'],{'color':'missing'})
        self.assertEqual(len(cs[-1]['state']),1)

    def test_labels_and_ids_are_valid_and_deterministic(self):
        cs=core_cases()+robustness_cases(core_cases())
        self.assertEqual(len({c['id'] for c in cs}),len(cs))
        self.assertEqual(digest(cs),digest(core_cases()+robustness_cases(core_cases())))
        for c in cs:
            self.assertEqual(set(c['questions']),set(c['expected']))
            for key,q in c['questions'].items():
                expected=c['expected'][key]
                if q['type']=='choice':self.assertIn(expected,q['criteria'])
                if q['type']=='score':self.assertIn(expected,range(len(q['criteria'])))
                if q['type']=='noul':self.assertIsInstance(expected,bool)

    def test_missing_answers_are_not_silent_passes(self):
        c=case('x','x','x',{'x':noul('x')},{'x':True})
        with self.assertRaises(ValueError):score(c,{'answers':{}})
        m=metrics([{'expected_count':3,'attempts':[],'error':'network'}])
        self.assertEqual((m['correct'],m['decisions'],m['errors']),(0,3,1))

    def test_score_mean_and_modal_class_are_distinct(self):
        c=case('x','x','x',{'x':{'type':'score','criteria':['low','mid','high']}},{'x':2})
        ans={'answers':{'x':{'type':'score','score':1.6,'probabilities':{'0':.1,'1':.2,'2':.7}}}}
        d=score(c,ans)['x'];self.assertTrue(d['correct']);self.assertAlmostEqual(d['absolute_error'],.4)
        ans['answers']['x']['score']=2
        with self.assertRaises(ValueError):score(c,ans)

    def test_refusals_and_cost_missingness(self):
        c=case('x','x','x',{'x':noul('x')},{'x':True})
        self.assertTrue(score(c,{'answers':{'x':{'type':'refusal'}}})['x']['refusal'])
        m=metrics([{'expected_count':1,'attempts':[{'response':{'usage':{'cost':0.1}}},{'status':503}],'error':'503'}])
        self.assertEqual(m['attempts_without_cost'],1);self.assertAlmostEqual(m['reported_cost_usd'],.1)


if __name__=='__main__':unittest.main()
