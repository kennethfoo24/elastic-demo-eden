import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';

interface KnowledgeArticle {
  sys_id: string;
  number: string;
  short_description: string;
  workflow_state: string;
  sys_created_on: string;
}

export default function KnowledgeList() {
  const [articles, setArticles] = useState<KnowledgeArticle[]>([]);

  useEffect(() => {
    const fetchData = () => {
      fetch('/_internal/knowledge').then((r) => r.json()).then(setArticles).catch(() => {});
    };
    fetchData();
    const interval = setInterval(fetchData, 3000);
    return () => clearInterval(interval);
  }, []);

  return (
    <div>
      <div className="flex items-center justify-between mb-6">
        <h1 className="text-2xl font-bold text-gray-900">Knowledge Base</h1>
        <span className="text-sm text-gray-500">{articles.length} total</span>
      </div>
      <div className="bg-white rounded-lg shadow border border-snow-border">
        {articles.length === 0 ? (
          <div className="text-center py-12 text-gray-500">
            <p className="text-lg">No knowledge articles yet</p>
            <p className="text-sm mt-1">Articles will appear here once seeded (kb_knowledge table)</p>
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="min-w-full divide-y divide-snow-border">
              <thead className="bg-gray-50">
                <tr>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Number</th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Short Description</th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Workflow State</th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Created</th>
                </tr>
              </thead>
              <tbody className="bg-white divide-y divide-snow-border">
                {articles.map((article) => (
                  <tr key={article.sys_id} className="hover:bg-gray-50 transition-colors">
                    <td className="px-4 py-3 text-sm">
                      <Link to={`/knowledge/${article.sys_id}`} className="text-blue-600 hover:text-blue-800 font-medium">
                        {article.number}
                      </Link>
                    </td>
                    <td className="px-4 py-3 text-sm text-gray-900 max-w-md truncate">{article.short_description}</td>
                    <td className="px-4 py-3 text-sm">
                      <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800">
                        {article.workflow_state}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-sm text-gray-500 whitespace-nowrap">{article.sys_created_on}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}
