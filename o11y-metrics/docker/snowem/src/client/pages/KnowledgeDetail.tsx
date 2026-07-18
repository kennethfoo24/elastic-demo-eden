import { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';

interface KnowledgeArticle {
  [key: string]: string;
}

const displayFields = ['number', 'short_description', 'workflow_state', 'sys_created_on', 'sys_updated_on', 'sys_created_by'];

export default function KnowledgeDetail() {
  const { sysId } = useParams<{ sysId: string }>();
  const [article, setArticle] = useState<KnowledgeArticle | null>(null);
  const [notFound, setNotFound] = useState(false);

  useEffect(() => {
    if (!sysId) return;
    fetch(`/_internal/knowledge/${sysId}`)
      .then((r) => {
        if (!r.ok) { setNotFound(true); return null; }
        return r.json();
      })
      .then((data) => { if (data) setArticle(data); })
      .catch(() => setNotFound(true));
  }, [sysId]);

  if (notFound) {
    return (
      <div className="text-center py-12">
        <p className="text-gray-500 text-lg">Article not found</p>
        <Link to="/knowledge" className="text-blue-600 hover:text-blue-800 text-sm mt-2 inline-block">
          Back to knowledge base
        </Link>
      </div>
    );
  }

  if (!article) {
    return <div className="text-center py-12 text-gray-500">Loading...</div>;
  }

  return (
    <div>
      <div className="flex items-center gap-3 mb-6">
        <Link to="/knowledge" className="text-blue-600 hover:text-blue-800 text-sm">&larr; Back</Link>
        <h1 className="text-2xl font-bold text-gray-900">{article.number}</h1>
      </div>

      <div className="bg-white rounded-lg shadow border border-snow-border">
        <div className="px-4 py-3 border-b border-snow-border">
          <h2 className="font-semibold text-gray-800">{article.short_description || 'Untitled'}</h2>
        </div>
        <div className="divide-y divide-snow-border">
          {displayFields
            .filter((f) => f !== 'short_description' && f !== 'number')
            .map((field) => {
              const value = article[field];
              if (!value) return null;
              return (
                <div key={field} className="px-4 py-2 grid grid-cols-3 gap-4 text-sm">
                  <span className="text-gray-500 font-medium">{formatFieldName(field)}</span>
                  <span className="col-span-2 text-gray-900 break-words">{value}</span>
                </div>
              );
            })}
        </div>
      </div>

      <div className="mt-4 bg-white rounded-lg shadow border border-snow-border p-4">
        <h3 className="font-semibold text-gray-800 mb-2 text-sm">text</h3>
        <p className="text-sm text-gray-900 whitespace-pre-wrap">{article.text || '—'}</p>
      </div>

      <div className="mt-4 bg-white rounded-lg shadow border border-snow-border p-4">
        <h3 className="font-semibold text-gray-800 mb-2 text-sm">sys_id</h3>
        <code className="text-xs bg-gray-100 px-2 py-1 rounded break-all">{article.sys_id}</code>
      </div>
    </div>
  );
}

function formatFieldName(field: string): string {
  return field.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
}
