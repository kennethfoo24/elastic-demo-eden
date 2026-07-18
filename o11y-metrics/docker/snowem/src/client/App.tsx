import { Routes, Route } from 'react-router-dom';
import Layout from './components/Layout';
import Dashboard from './pages/Dashboard';
import IncidentList from './pages/IncidentList';
import IncidentDetail from './pages/IncidentDetail';
import KnowledgeList from './pages/KnowledgeList';
import KnowledgeDetail from './pages/KnowledgeDetail';
import ActivityLog from './pages/ActivityLog';

export default function App() {
  return (
    <Layout>
      <Routes>
        <Route path="/" element={<Dashboard />} />
        <Route path="/incidents" element={<IncidentList />} />
        <Route path="/incidents/:sysId" element={<IncidentDetail />} />
        <Route path="/knowledge" element={<KnowledgeList />} />
        <Route path="/knowledge/:sysId" element={<KnowledgeDetail />} />
        <Route path="/activity" element={<ActivityLog />} />
      </Routes>
    </Layout>
  );
}
